require "test_helper"

# Release (PRD Lifecycle L103, L123, L505): the holder gives the task back
# with a reason from the registry; the task goes to Ready with no holder and
# no builder, and criteria that passed stay passed. Allowed under a hold.
class ReleaseTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @task = @scenario.task(state: "working", builder: @builder)
    @criterion = Criterion.where(task_id: @task.id, kind: "build").first
  end

  def apply(command, seat, params = {})
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def release(seat = @builder, reason: "unable_to_continue")
    apply("release", seat, "id" => @task.id, "reason" => reason)
  end

  test "releases: Ready, no holder, no builder, no lease; passed criteria stay passed" do
    @criterion.update!(state: "passed", passed_by_seat_id: @builder.id)
    assert release.completed?

    @task.reload
    assert_equal [ "ready", nil, nil, nil ], @task.attributes.values_at("state", "holder_seat_id", "builder_seat_id", "lease_due_at")
    assert_equal "passed", @criterion.reload.state
    event = written.sole
    assert_equal [ "task.released", "seat", @builder.id, { "reason" => "unable_to_continue", "wait_cause" => nil } ],
      [ event.type, event.actor_kind, event.actor_id, event.payload ]
  end

  test "the seat may claim again at once" do
    release(reason: "stopping")
    assert apply("claim", @builder).completed?
  end

  test "a reason the app chooses is 422 invalid from a seat" do
    assert_raises(T::Invalid) { release(reason: "seat_removed") }
    assert_equal "working", @task.reload.state
  end

  test "it is allowed while the task is held, and the hold stays open" do
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "rounds_exceeded", facts: { round: 0 })
    end
    assert release.completed?
    assert Hold.exists?(task_id: @task.id, reason: "rounds_exceeded", closed_at: nil)
  end

  test "a hold bound to the seat closes when the seat loses the task (SM-15)" do
    hold = ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "seat_paused")
    end
    assert release.completed?
    assert_equal %w[task.released hold.closed], written.map(&:type)
    assert hold.reload.closed_at
  end

  test "a seat that does not hold the task is not_holder" do
    assert_equal "not_holder", release(@scenario.seat(role: "builder")).refusal.code
  end

  # --- Milestone 3 (its plan, WP4, HE-35, SM-15) ---------------------------

  test "every seat-bound hold closes after task.released, each hold.closed then its item, by the seat" do
    credential = @scenario.credential
    paused, signed_out = ActiveRecord::Base.transaction(requires_new: true) do
      ctx = @scenario.context
      [ Leverage::Holds.open(ctx, task: @task, reason: "seat_paused"),
        Leverage::Holds.open(ctx, task: @task, reason: "credential_signed_out", credential_id: credential.id) ]
    end
    assert release.completed?

    assert_equal %w[task.released hold.closed hold.closed inbox.resolved], written.map(&:type)
    released, first, second, = written
    assert_equal [ paused.id, signed_out.id ], [ first.subject_id, second.subject_id ]
    assert_equal({ "reason" => "unable_to_continue", "wait_cause" => nil }, released.payload)
    written.each { |event| assert_equal [ "seat", @builder.id, released.effective_at ], [ event.actor_kind, event.actor_id, event.effective_at ] }
    assert_equal "wait_ready", TaskStep.find_by!(task_id: @task.id, closed_at: nil).kind
  end

  test "the wait_cause goes on task.released with no hold, and on the last hold.closed under one (HE-35)" do
    scenario = Scenario.new
    own = scenario.limit_credential(scenario.credential, reset_at: scenario.database_now + 3600)
    builder = scenario.seat(role: "builder", credential: own)
    free = scenario.task(state: "working", builder: builder)
    @scenario = scenario
    @task = free
    assert release(builder).completed?
    assert_equal({ "reason" => "unable_to_continue", "wait_cause" => "credential_limit" }, written.sole.payload)
    assert_equal [ "wait_ready", "credential_limit" ], TaskStep.find_by!(task_id: free.id, closed_at: nil).values_at(:kind, :cause_kind)

    @task = scenario.task(state: "working", builder: builder)
    scenario.hold(@task, reason: "credential_limit", credential: own, item: false)
    assert release(builder).completed?
    released, closed = written
    assert_equal [ nil, "credential_limit" ], [ released.payload.fetch("wait_cause"), closed.payload.fetch("wait_cause") ]
    assert_equal [ "wait_ready", "credential_limit", closed.id ],
      TaskStep.find_by!(task_id: @task.id, closed_at: nil).values_at(:kind, :cause_kind, :opening_event_id)
  end

  test "a hold not bound to the seat stays open, so neither the release nor hold.closed carries a wait_cause" do
    paused, owner_hold = ActiveRecord::Base.transaction(requires_new: true) do
      ctx = @scenario.context
      [ Leverage::Holds.open(ctx, task: @task, reason: "seat_paused"), Leverage::Holds.open(ctx, task: @task, reason: "owner_hold") ]
    end
    assert release.completed?

    assert_equal %w[task.released hold.closed], written.map(&:type)
    assert_equal [ nil, nil ], written.map { |event| event.payload.fetch("wait_cause") }
    assert paused.reload.closed_at
    assert_nil owner_hold.reload.closed_at
    assert_equal "wait_owner", TaskStep.find_by!(task_id: @task.id, closed_at: nil).kind
  end
end
