require "test_helper"
require_relative "owner_controls_support"

# Change a seat (PRD L148, L258; milestone 3 plan HE-27, HE-10, HM-51):
# only the fields the request sets change, and seat.changed is written.
# Name, model, effort and strength rank apply at once. A new login must be
# an added login, brings its provider, applies from the seat's next claim,
# and makes Handoff.reevaluate look at the open credential hold of the
# task the seat holds; the login cannot be emptied. A change of role is
# invalid_state while the seat holds a task or a review. Turning the seat
# off clears wanted_running, queues stop_seat, and releases a Working task
# it holds with seat_disabled, caused by seat.changed, closing its
# seat-bound holds; a review it holds is released when its run is reported
# stopped (IF-21). Turning it on starts nothing.
class ChangeSeatTest < ActiveSupport::TestCase
  include OwnerControlsSupport

  setup do
    use_scenario
    @login = scenario.credential
    @builder = scenario.seat(role: "builder", credential: @login, run_state: "running", wanted_running: true)
  end

  def change(seat, **fields) = owner_run("change_seat", { "id" => seat.id }.merge(fields.transform_keys(&:to_s)))

  test "name, model, effort and strength rank change at once, with seat.changed by the owner" do
    outcome, events = change(@builder, name: "Made-up renamed", model: "made-up-model-2", effort: "high",
      strength_rank: 3)

    assert_completed(outcome)
    event = events.sole
    assert_equal [ "seat.changed", "owner", scenario.owner.id, "seat", @builder.id, nil, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.task_id, event.payload ]
    assert_equal [ "Made-up renamed", "made-up-model-2", "high", 3 ],
      @builder.reload.attributes.values_at("name", "model", "effort", "strength_rank")
  end

  test "only the fields sent change; a null model or effort is the tool's default, a null rank the seats' default" do
    @builder.update!(model: "made-up-model", effort: "low", strength_rank: 4)
    change(@builder, model: nil, effort: nil)
    assert_equal [ @builder.name, "", "", 4, @builder.role ],
      @builder.reload.attributes.values_at("name", "model", "effort", "strength_rank", "role")

    change(@builder, strength_rank: nil)
    assert_equal 1, @builder.reload.strength_rank
  end

  # Review: a change that changes nothing writes no seat.changed.
  test "an empty change, or one that sets every field to what it is, completes with no event and changes nothing" do
    before = @builder.reload.attributes.except("updated_at")
    outcome, events = change(@builder)

    assert_equal({ "helper_request_id" => nil }, assert_completed(outcome).result)
    assert_empty events
    assert_equal before, @builder.reload.attributes.except("updated_at")

    outcome, events = change(@builder, name: @builder.name, model: @builder.model, effort: @builder.effort,
      strength_rank: @builder.strength_rank, role: @builder.role, enabled: true, credential_id: @login.id)
    assert_completed(outcome)
    assert_empty events
    assert_equal before, @builder.reload.attributes.except("updated_at")
  end

  test "an empty name is 422 invalid" do
    assert_raises(T::Invalid) { change(@builder, name: "") }
  end

  test "a change of role while the seat holds nothing" do
    outcome, = change(@builder, role: "reviewer")

    assert_completed(outcome)
    assert_equal "reviewer", @builder.reload.role
  end

  test "a change of role is invalid_state while the seat holds a task or a review" do
    working_task(@builder)
    outcome, events = change(@builder, role: "reviewer")
    assert_refused("invalid_state", outcome)
    assert_empty events
    assert_equal "builder", @builder.reload.role

    reviewer = scenario.seat(role: "reviewer", credential: @login)
    scenario.review(scenario.task(state: "in_review"), reviewer: reviewer)
    outcome, = change(reviewer, role: "builder")
    assert_refused("invalid_state", outcome)
  end

  test "the same role is no change of role, also while the seat holds a task" do
    working_task(@builder)
    outcome, = change(@builder, role: "builder", name: "Made-up renamed")

    assert_completed(outcome)
  end

  test "planner and orchestrator are 422 invalid in this milestone" do
    assert_raises(T::Invalid) { change(@builder, role: "planner") }
    assert_raises(T::Invalid) { change(@builder, role: "orchestrator") }
  end

  test "a new login: credential and provider change, the run is not touched, and no task means no look" do
    other = scenario.credential(provider: "codex")
    calls = recording(Leverage::Handoff, :reevaluate) do
      outcome, events = change(@builder, credential_id: other.id)
      assert_completed(outcome)
      assert_equal %w[seat.changed], events.map(&:type)
    end

    assert_equal [ other.id, "codex" ], @builder.reload.attributes.values_at("credential_id", "provider")
    assert_equal @login.id, @builder.run_credential_id
    assert_empty HelperRequest.where(seat_id: @builder.id)
    assert_empty calls
  end

  test "a new login makes Handoff.reevaluate look at the open credential hold of the task the seat holds" do
    task = working_task(@builder)
    open_hold(task, "credential_limit", credential: @login, item: false)
    other = scenario.credential(provider: "codex")
    events = nil
    calls = recording(Leverage::Handoff, :reevaluate) { _, events = change(@builder, credential_id: other.id) }

    args, keywords = calls.sole
    changed = events.first
    assert_equal "seat.changed", changed.type
    assert_equal [ [ task.id ], changed.id ], [ keywords.fetch(:tasks).map(&:id), keywords.fetch(:cause).id ]
    assert_equal %i[tasks cause], keywords.keys
    assert_equal 1, args.size
  end

  test "a new login does not look at a task held for another reason" do
    task = working_task(@builder)
    owner_run("hold", "id" => task.id)
    calls = recording(Leverage::Handoff, :reevaluate) { change(@builder, credential_id: scenario.credential.id) }

    assert_empty calls
  end

  test "the same login is no change of login: no look" do
    task = working_task(@builder)
    open_hold(task, "credential_limit", credential: @login, item: false)
    calls = recording(Leverage::Handoff, :reevaluate) { change(@builder, credential_id: @builder.credential_id) }

    assert_empty calls
  end

  test "the login cannot be emptied: 422 invalid" do
    assert_raises(T::Invalid) { change(@builder, credential_id: nil) }
    assert_equal @builder.credential_id, @builder.reload.credential_id
  end

  test "a login whose add is still running, or an API token, is 422 invalid" do
    pending_add = scenario.credential(added: false)
    token = scenario.credential(kind: "api_token")
    assert_raises(T::Invalid) { change(@builder, credential_id: pending_add.id) }
    assert_raises(T::Invalid) { change(@builder, credential_id: token.id) }
  end

  test "an unknown login, or one of another workspace, is not found" do
    other_workspace = Scenario.new
    assert_raises(T::NotFound) { change(@builder, credential_id: SecureRandom.uuid) }
    assert_raises(T::NotFound) { change(@builder, credential_id: other_workspace.credential.id) }
  end

  test "a seat that connects on its own has no login to change: 422 invalid" do
    seat = own_seat
    assert_raises(T::Invalid) { change(seat, credential_id: @login.id) }
  end

  test "turning off a seat with a Working task: seat.changed, task.released seat_disabled caused by it, stop_seat" do
    task = working_task(@builder)
    outcome, events = change(@builder, enabled: false)

    assert_completed(outcome)
    changed, released = events
    assert_equal %w[seat.changed task.released], events.map(&:type)
    assert_equal [ "owner", scenario.owner.id, changed.id, task.id ],
      [ released.actor_kind, released.actor_id, released.cause_id, released.task_id ]
    assert_equal({ "reason" => "seat_disabled", "wait_cause" => nil }, released.payload)
    task.reload
    assert_equal [ "ready", nil, nil, nil ], task.attributes.values_at("state", "holder_seat_id", "builder_seat_id", "lease_due_at")
    @builder.reload
    assert_equal [ false, false ], @builder.attributes.values_at("enabled", "wanted_running")
    stop = HelperRequest.where(seat_id: @builder.id).sole
    assert_equal [ "stop_seat", "queued" ], [ stop.kind, stop.state ]
    assert_equal({ "helper_request_id" => stop.id }, outcome.result)
  end

  test "turning off closes the released task's seat-bound holds through Holds.close_seat_bound" do
    task = working_task(@builder)
    events = nil
    calls = recording(Leverage::Holds, :close_seat_bound) { _, events = change(@builder, enabled: false) }

    released = events.find { |event| event.type == "task.released" }
    args, keywords = calls.sole
    assert_equal [ task.id, released.id ], [ args[1].id, keywords.fetch(:cause).id ]
    assert_nil keywords.fetch(:wait_cause), "no other builder: the wait is not for an account (HE-35)"
  end

  test "the wait_cause given is credential_limit when the only free builder has no available account (HE-35)" do
    working_task(@builder)
    limited = scenario.limit_credential(scenario.credential, reset_at: 1.hour.from_now)
    scenario.seat(role: "builder", credential: limited)
    calls = recording(Leverage::Holds, :close_seat_bound) { change(@builder, enabled: false) }

    assert_equal "credential_limit", calls.sole.last.fetch(:wait_cause)
  end

  test "turning off a seat that holds a review keeps the review until its run is reported stopped" do
    reviewer = running_seat(role: "reviewer")
    review = scenario.review(scenario.task(state: "in_review"), reviewer: reviewer)
    outcome, events = change(reviewer, enabled: false)

    assert_completed(outcome)
    assert_equal %w[seat.changed], events.map(&:type)
    assert_equal reviewer.id, review.reload.reviewer_seat_id
    assert_equal "stop_seat", HelperRequest.where(seat_id: reviewer.id).sole.kind
  end

  test "turning off a seat that connects on its own queues nothing" do
    seat = own_seat
    outcome, events = change(seat, enabled: false)

    assert_completed(outcome)
    assert_equal %w[seat.changed], events.map(&:type)
    assert_empty HelperRequest.where(seat_id: seat.id)
    assert_equal({ "helper_request_id" => nil }, outcome.result)
  end

  test "turning on starts nothing" do
    @builder.update!(enabled: false, wanted_running: false)
    outcome, events = change(@builder, enabled: true)

    assert_completed(outcome)
    assert_equal %w[seat.changed], events.map(&:type)
    assert_equal [ true, false ], @builder.reload.attributes.values_at("enabled", "wanted_running")
    assert_empty HelperRequest.where(seat_id: @builder.id)
  end

  # Review: a change that changes nothing writes no seat.changed.
  test "turning off a seat that is already off releases nothing, queues nothing and writes nothing" do
    @builder.update!(enabled: false, wanted_running: false)
    outcome, events = change(@builder, enabled: false)

    assert_completed(outcome)
    assert_empty events
    assert_empty HelperRequest.where(seat_id: @builder.id)
  end

  test "a removed or unknown seat is not found" do
    scenario.remove(@builder)
    assert_raises(T::NotFound) { change(@builder, name: "Made-up") }
    assert_raises(T::NotFound) { owner_run("change_seat", "id" => SecureRandom.uuid) }
  end
end
