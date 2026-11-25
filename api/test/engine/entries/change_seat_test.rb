require "test_helper"
require_relative "owner_controls_support"
require_relative "pending_ends_support"

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
#
# Milestone 4 (plan WP5b, §2.1 rule 11, §0.1 facts 12 and 28): all four
# roles are accepted; a change that disables the seat cancels, with
# invalid_state and before task.released, the pending submit of the Working
# task it takes, and the provisional claim it holds; it cancels a pending
# pass of a reviewer only when the stopped run is reported (IF-21), and a
# change that does not disable the seat cancels nothing. A job the seat
# holds as a checker is left to its run timeout.
class ChangeSeatTest < ActiveSupport::TestCase
  include OwnerControlsSupport
  include PendingEndsSupport

  setup do
    use_scenario
    @login = scenario.credential
    @builder = scenario.seat(role: "builder", credential: @login, run_state: "running", wanted_running: true, model: "")
  end

  def change(seat, **fields) = owner_run("change_seat", { "id" => seat.id }.merge(fields.transform_keys(&:to_s)))

  test "name, model, effort and strength rank change at once, with seat.changed by the owner" do
    outcome, events = change(@builder, name: "Made-up renamed", model: "claude-opus-5-5", effort: "high",
      strength_rank: 3)

    assert_completed(outcome)
    event = events.sole
    assert_equal [ "seat.changed", "owner", scenario.owner.id, "seat", @builder.id, nil, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.task_id, event.payload ]
    assert_equal [ "Made-up renamed", "claude-opus-5-5", "high", 3 ],
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

  test "a running app seat changing to or from General queues the replacement start on its current placement" do
    next_login = scenario.credential(provider: "codex", model: "made-up-codex-model")
    scenario.limit_credential(@login, reset_at: 1.hour.from_now)
    token_hash = @builder.token_hash

    %w[general reviewer].each do |role|
      outcome, events = change(@builder, role: role)

      assert_completed(outcome)
      assert_equal %w[seat.changed], events.map(&:type)
      queued = HelperRequest.where(seat_id: @builder.id, state: "queued")
      assert_equal 1, queued.size
      request = queued.sole
      assert_equal [ "start_seat", next_login.id, role, "codex", "made-up-codex-model" ],
        [ request.kind, request.credential_id, *request.params.values_at("role", "provider", "model") ]
      assert_equal({ "helper_request_id" => request.id }, outcome.result)
      assert_equal [ token_hash, @login.id ], @builder.reload.attributes.values_at("token_hash", "run_credential_id")
      request.update!(state: "finished", finished_at: scenario.database_now)
    end
  end

  test "changing between Builder and General keeps approved action work assigned" do
    seat = own_seat(role: "builder")
    task = scenario.finishing_task(builder: seat, holder: false, actions: [ { kind: "send", state: "approved" } ])

    outcome, events = change(seat, role: "general")
    assert_completed(outcome)
    refute_includes events.map(&:type), "hold.opened"
    assert_equal [ "finishing", seat.id ], task.reload.attributes.values_at("state", "builder_seat_id")

    task.update!(holder_seat_id: nil, lease_due_at: nil, lease_time_left_while_paused: nil)
    outcome, events = change(seat, role: "builder")
    assert_completed(outcome)
    refute_includes events.map(&:type), "hold.opened"
    assert_equal [ "finishing", seat.id ], task.reload.attributes.values_at("state", "builder_seat_id")
  end

  test "changing away from General opens Unconfirmed action when the new role does not build" do
    seat = own_seat(role: "general")
    task = scenario.finishing_task(builder: seat, holder: false, actions: [ { kind: "send", state: "approved" } ])

    outcome, events = change(seat, role: "reviewer")

    assert_completed(outcome)
    assert_equal %w[seat.changed hold.opened inbox.opened], events.map(&:type)
    assert_equal "action_unconfirmed", Hold.find_by!(task_id: task.id, closed_at: nil).reason
  end

  test "changing from Orchestrator to General opens no Unconfirmed action" do
    seat = own_seat(role: "orchestrator")
    task = scenario.finishing_task(builder: seat, holder: false, actions: [ { kind: "send", state: "approved" } ])

    outcome, = change(seat, role: "general")

    assert_completed(outcome)
    refute Hold.exists?(task_id: task.id, reason: "action_unconfirmed")
  end

  test "changing from Builder to Reviewer still opens Unconfirmed action and queues no helper request" do
    task = scenario.finishing_task(builder: @builder, holder: false, actions: [ { kind: "send", state: "approved" } ])

    outcome, events = change(@builder, role: "reviewer")

    assert_completed(outcome)
    assert_equal %w[seat.changed hold.opened inbox.opened], events.map(&:type)
    assert_equal "action_unconfirmed", Hold.find_by!(task_id: task.id, closed_at: nil).reason
    assert_equal({ "helper_request_id" => nil }, outcome.result)
    assert_empty HelperRequest.where(seat_id: @builder.id)
  end

  test "changing to General while an app seat is stopped queues no start" do
    @builder.update!(run_state: "stopped")
    outcome, = change(@builder, role: "general")

    assert_equal({ "helper_request_id" => nil }, assert_completed(outcome).result)
    assert_empty HelperRequest.where(seat_id: @builder.id)
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

  test "all four roles are accepted: a seat that holds nothing becomes a planner, an orchestrator, a reviewer again" do
    %w[planner orchestrator reviewer builder].each do |role|
      outcome, events = change(@builder, role: role)

      assert_completed(outcome)
      assert_equal %w[seat.changed], events.map(&:type)
      assert_equal role, @builder.reload.role
    end
  end

  test "a role of no kind is 422 invalid" do
    assert_raises(T::Invalid) { change(@builder, role: "owner") }
    assert_raises(T::Invalid) { change(@builder, role: nil) }
    assert_equal "builder", @builder.reload.role
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

  [ 0, 4 ].each do |rank|
    test "change_seat refuses strength rank #{rank} (AP-24)" do
      written = events_written { assert_raises(T::Invalid) { change(@builder, strength_rank: rank) } }

      assert_empty written
      assert_equal 1, @builder.reload.strength_rank
    end
  end

  test "renaming or reassigning the login within the same provider preserves a legacy model and effort" do
    @builder.update!(model: "made-up-old-model", effort: "made-up-old-effort")
    login = scenario.credential(provider: @builder.provider)

    assert_completed(change(@builder, name: "Made-up renamed").first)
    assert_completed(change(@builder, credential_id: login.id).first)
    assert_equal [ "Made-up renamed", login.id, "made-up-old-model", "made-up-old-effort" ],
      @builder.reload.attributes.values_at("name", "credential_id", "model", "effort")
  end

  test "a model change or a different provider validates the resulting model and effort together" do
    @builder.update!(model: "claude-opus-5-5", effort: "high")
    login = scenario.credential(provider: "codex")

    assert_raises(T::Invalid) { change(@builder, model: "made-up-new-model") }
    assert_raises(T::Invalid) { change(@builder, credential_id: login.id) }
    assert_raises(T::Invalid) { change(@builder, credential_id: login.id, model: "gpt-6.2-astra") }

    assert_completed(change(@builder, credential_id: login.id, model: "gpt-6.2-astra", effort: nil).first)
    assert_equal [ login.id, "codex", "gpt-6.2-astra", "" ], @builder.reload.attributes.values_at("credential_id", "provider", "model", "effort")
  end

  test "the owner cannot set or clear a Prompt seat's reported model or effort" do
    seat = own_seat
    [ { model: "claude-opus-5-5" }, { model: nil }, { effort: nil } ].each do |fields|
      assert_raises(T::Invalid) { change(seat, **fields) }
    end
  end

  test "Deliver off cancels a pending submit before releasing its Working task and closes the seat-bound hold" do
    task = working_task(@builder)
    hold = open_hold(task, "credential_limit", credential: @login, item: false)
    pending = scenario.pending_transition(task, command: "submit", requester: @builder)
    receipt = Command.create!(workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: @builder.id,
      key: pending.command_key, command: "submit", request_hash: "made-up", outcome: "pending", pending_transition_id: pending.id)
    permissions = { "work" => true, "deliver" => false, "create" => true }
    outcome, events = change(@builder, permissions: permissions)

    assert_equal({ "helper_request_id" => nil }, assert_completed(outcome).result)
    changed, released, closed = events
    assert_equal %w[seat.changed task.released hold.closed], events.map(&:type)
    assert_equal [ task.id, changed.id, "deliver_turned_off" ], [ released.task_id, released.cause_id, released.payload.fetch("reason") ]
    assert_equal [ hold.id, released.command_id ], [ closed.subject_id, closed.command_id ]
    assert_not_nil hold.reload.closed_at
    assert_equal [ "ready", nil, nil, nil ], task.reload.attributes.values_at("state", "holder_seat_id", "builder_seat_id", "lease_due_at")
    assert_equal "cancelled", pending.reload.state
    assert_equal [ "refused", "invalid_state", true ], [ receipt.reload.outcome, receipt.refusal.fetch("code"), receipt.notify ]
    assert_equal [ true, false, true, true, true ], @builder.reload.attributes.values_at("may_work", "may_deliver", "may_create", "enabled", "wanted_running")
    assert_empty HelperRequest.where(seat_id: @builder.id)
  end

  test "Deliver off cancels a provisional claim and releases its reservation without a task release event" do
    task = scenario.task(state: "ready")
    task.update!(holder_seat_id: @builder.id)
    pending = scenario.pending_transition(task, command: "claim", requester: @builder)
    permissions = { "work" => true, "deliver" => false, "create" => true }

    outcome, events = change(@builder, permissions: permissions)

    assert_completed(outcome)
    assert_equal %w[seat.changed], events.map(&:type)
    assert_equal [ "ready", nil ], task.reload.attributes.values_at("state", "holder_seat_id")
    assert_equal "cancelled", pending.reload.state

    repeated, events = change(@builder, permissions: permissions)
    assert_completed(repeated)
    assert_empty events
  end

  test "Deliver off leaves the builder's current and waiting approved outward actions assigned" do
    waiting = scenario.finishing_task(builder: @builder, holder: false, actions: [ { kind: "send", state: "approved" } ])
    active = scenario.finishing_task(builder: @builder, holder: true, actions: [ { kind: "send", state: "approved" } ])
    actions = Action.where(task_id: [ active.id, waiting.id ]).order(:id)
    approval = actions.pluck(:id, :state, :approved_by_kind, :approved_by_id)
    permissions = { "work" => true, "deliver" => false, "create" => true }

    outcome, events = change(@builder, permissions: permissions)

    assert_completed(outcome)
    assert_equal %w[seat.changed], events.map(&:type)
    assert_equal [ "finishing", @builder.id, @builder.id ], active.reload.attributes.values_at("state", "builder_seat_id", "holder_seat_id")
    assert_equal [ "finishing", @builder.id, nil ], waiting.reload.attributes.values_at("state", "builder_seat_id", "holder_seat_id")
    assert_equal approval, actions.pluck(:id, :state, :approved_by_kind, :approved_by_id)
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

  test "disabling a builder whose submit is pending cancels it with invalid_state after seat.changed, before task.released" do
    task = working_task(@builder)
    pending = scenario.pending_transition(task, command: "submit", requester: @builder)
    events = nil
    calls = recording_cancels { _, events = change(@builder, enabled: false) }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", %w[seat.changed]) ], calls
    assert_equal %w[seat.changed task.released], events.map(&:type)
  end

  test "disabling a provisional claimant cancels the claim with invalid_state; the cancel is all the task gets" do
    task = scenario.task(state: "ready")
    task.update!(holder_seat_id: @builder.id)
    pending = scenario.pending_transition(task, command: "claim", requester: @builder)
    events = nil
    outcome = nil
    calls = recording_cancels { outcome, events = change(@builder, enabled: false) }

    assert_completed(outcome)
    assert_equal [ Cancelled.new(pending.id, "invalid_state", %w[seat.changed]) ], calls
    assert_equal %w[seat.changed], events.map(&:type)
    assert_equal "stop_seat", HelperRequest.where(seat_id: @builder.id).sole.kind
  end

  test "disabling a reviewer cancels no pending pass: that comes when its stopped run is reported (IF-21)" do
    reviewer = running_seat(role: "reviewer")
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)
    pending = scenario.pending_transition(task, command: "pass_review", requester: reviewer)
    calls = recording_cancels { change(reviewer, enabled: false) }

    assert_empty calls
    assert_equal [ reviewer.id, "pending" ], [ review.reload.reviewer_seat_id, pending.reload.state ]

    written = nil
    calls = recording_cancels do
      written = events_written do
        assert_completed(helper_command("report_run_stopped", { "id" => reviewer.id, "credential_id" => reviewer.run_credential_id,
          "observed_at" => "2026-11-19T12:00:00Z", "stop_reason" => "stopped" }))
      end
    end

    assert_equal [ Cancelled.new(pending.id, "invalid_state", []) ], calls
    assert_equal %w[review.released], written.map(&:type)
  end

  test "a change that does not disable the seat cancels nothing, under a pending submit or a provisional claim" do
    task = working_task(@builder)
    scenario.pending_transition(task, command: "submit", requester: @builder)
    claimant = running_seat
    ready = scenario.task(state: "ready")
    ready.update!(holder_seat_id: claimant.id)
    scenario.pending_transition(ready, command: "claim", requester: claimant)
    calls = recording_cancels do
      change(@builder, name: "Made-up renamed", model: "claude-opus-5-5", enabled: true)
      change(claimant, model: "claude-opus-5-5", effort: "high")
    end

    assert_empty calls
  end

  test "disabling a seat that is already off, or one that holds nothing pending, cancels nothing" do
    @builder.update!(enabled: false, wanted_running: false)
    scenario.pending_transition(working_task(@builder), command: "submit", requester: @builder)
    idle = running_seat
    calls = recording_cancels do
      change(@builder, enabled: false)
      change(idle, enabled: false)
    end

    assert_empty calls
  end

  test "disabling an orchestrator leaves the job it claimed to its run timeout: no job event" do
    orchestrator = scenario.orchestrator(credential: @login, run_state: "running", wanted_running: true)
    task = scenario.task(state: "ready")
    scenario.rule_check(task, rule: scenario.rule(hook: "task.before_claim"), started: true, checker: orchestrator)
    job = Job.where(claimed_by_seat_id: orchestrator.id).sole
    outcome, events = change(orchestrator, enabled: false)

    assert_completed(outcome)
    assert_equal %w[seat.changed], events.map(&:type)
    assert_equal [ "claimed", orchestrator.id ], Job.find(job.id).attributes.values_at("state", "claimed_by_seat_id")
  end
end
