require "test_helper"

# The builder_lease_expiry timer (PRD L119-L123; timers.json; milestone 2
# plan WP5, EN-14, EN-17): a builder's lease that reaches its due time ends.
# The task goes back to Ready with no holder and keeps its builder seat and
# every passed criterion; task.lease_expired is written by the app, with
# no command_id, at the due time. Run as its own command (the sweep), it
# takes one task (params task_id) or every due task of the workspace, oldest
# due first, at most params limit of them.
class BuilderLeaseExpiryTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @builder = @scenario.seat(role: "builder")
  end

  def timer(params = {})
    T.apply(T::Request.new(command: "builder_lease_expiry", workspace_id: @scenario.workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: params))
  end

  def expiries(scenario = @scenario)
    Event.where(workspace_id: scenario.workspace_id, type: "task.lease_expired").order(:seq).to_a
  end

  test "a due lease on one task ends: Ready, no holder, the builder seat kept, the event at the due time" do
    task = @scenario.task(state: "working", builder: @builder)
    task.update_columns(resume_pending_since: @scenario.database_now)
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    criterion.update_columns(state: "passed", passed_by_seat_id: @builder.id, passed_at: @scenario.database_now)
    due = @scenario.database_now
    @scenario.make_due(task, at: due)
    commands_before = Command.count

    outcome = timer("task_id" => task.id)

    assert outcome.completed?
    assert_equal({ "expired_task_ids" => [ task.id ] }, outcome.result)
    task.reload
    assert_equal "ready", task.state
    assert_nil task.holder_seat_id
    assert_nil task.lease_due_at
    assert_nil task.lease_time_left_while_paused
    assert_nil task.resume_pending_since, "no builder is left to resume"
    assert_nil task.builder_seat_id, "back in Ready, the task has no builder (PRD, What the replay test rebuilds)"
    assert_equal "passed", criterion.reload.state, "no criterion is reopened (L123)"

    event = expiries.sole
    assert_in_delta due.to_f, event.effective_at.to_f, 0.000_001
    assert_equal [ "app", nil, nil, nil, nil ],
      [ event.actor_kind, event.actor_id, event.command_id, event.subject_kind, event.subject_id ]
    assert_equal task.round, event.round
    assert_equal Command.count, commands_before, "the app's own command stores no commands row"
  end

  test "a lease that is not due yet is left as it is" do
    task = @scenario.task(state: "working", builder: @builder)

    outcome = timer("task_id" => task.id)

    assert outcome.completed?
    assert_equal({ "expired_task_ids" => [] }, outcome.result)
    assert_equal "working", task.reload.state
    assert_empty expiries
  end

  test "a paused lease is never due" do
    task = @scenario.task(state: "working", builder: @builder)
    task.update_columns(lease_due_at: @scenario.database_now - 600, lease_time_left_while_paused: 120)

    assert_equal [], timer("task_id" => task.id).result.fetch("expired_task_ids")
    assert_equal [], timer.result.fetch("expired_task_ids")
    assert_equal "working", task.reload.state
  end

  test "with no task named it ends every due lease of the workspace, oldest due first, and no other's" do
    now = @scenario.database_now
    later = @scenario.make_due(@scenario.task(state: "working", builder: @builder), at: now - 10)
    earlier = @scenario.make_due(@scenario.task(state: "working", builder: @scenario.seat(role: "builder")), at: now - 20)
    running = @scenario.task(state: "working", builder: @scenario.seat(role: "builder"))
    other = Scenario.new
    elsewhere = other.make_due(other.task(state: "working", builder: other.seat(role: "builder")))

    outcome = timer

    assert_equal [ earlier.id, later.id ], outcome.result.fetch("expired_task_ids")
    assert_equal [ earlier.id, later.id ], expiries.map(&:task_id)
    assert_equal "working", running.reload.state
    assert_equal "working", elsewhere.reload.state
  end

  test "limit bounds one run; the next run takes the rest" do
    now = @scenario.database_now
    tasks = 3.times.map do |index|
      @scenario.make_due(@scenario.task(state: "working", builder: @scenario.seat(role: "builder")), at: now - 30 + index)
    end

    assert_equal tasks.first(2).map(&:id), timer("limit" => 2).result.fetch("expired_task_ids")
    assert_equal [ tasks.last.id ], timer("limit" => 2).result.fetch("expired_task_ids")
    assert_equal [], timer("limit" => 2).result.fetch("expired_task_ids")
  end

  test "a task from another workspace is not found" do
    other = Scenario.new
    task = other.task(state: "working", builder: other.seat(role: "builder"))

    assert_raises(T::NotFound) { timer("task_id" => task.id) }
  end

  test "a task that is not Working is refused invalid_state and nothing is written" do
    task = @scenario.task(state: "ready")
    task.update_columns(lease_due_at: @scenario.database_now - 1)
    before = Workspace.find(@scenario.workspace_id).last_seq

    outcome = timer("task_id" => task.id)

    assert outcome.refused?
    assert_equal "invalid_state", outcome.refusal.code
    assert_equal before, Workspace.find(@scenario.workspace_id).last_seq
  end

  test "the builder who lost the lease is told lease_expired afterwards" do
    task = @scenario.make_due(@scenario.task(state: "working", builder: @builder))
    timer("task_id" => task.id)

    assert Leverage::Leases.ended_by_expiry?(task.reload, @builder)
  end

  # --- Milestone 3 (its plan, WP4, HE-35, SM-15) ---------------------------

  # A builder whose only account is limited with no reset time, holding a
  # Working task under a credential_limit hold, and no other builder.
  def limited_builder_task(hold: true)
    scenario = Scenario.new(lease_length_seconds: 600)
    own = scenario.limit_credential(scenario.credential, reset_at: nil)
    builder = scenario.seat(role: "builder", credential: own)
    task = scenario.task(state: "working", builder: builder)
    held = scenario.hold(task, reason: "credential_limit", credential: own) if hold
    [ scenario, task, held ]
  end

  def timer_in(scenario, params)
    T.apply(T::Request.new(command: "builder_lease_expiry", workspace_id: scenario.workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: params))
  end

  test "under a credential_limit hold the lease still ends; the seat-bound hold then closes with the wait_cause" do
    scenario, task, hold = limited_builder_task
    due = scenario.database_now
    scenario.make_due(task, at: due)

    assert timer_in(scenario, "task_id" => task.id).completed?

    events = Event.where(task_id: task.id).where("seq > ?", Event.where(subject_id: hold.id, type: "hold.opened").pick(:seq))
      .where.not(type: %w[inbox.opened]).order(:seq).to_a
    assert_equal %w[task.lease_expired hold.closed inbox.resolved], events.map(&:type)
    expired, closed, resolved = events
    assert_equal({ "wait_cause" => nil }, expired.payload, "the step stays on the hold until hold.closed")
    assert_equal [ hold.id, "credential_limit" ], [ closed.subject_id, closed.payload.fetch("wait_cause") ]
    [ expired, closed, resolved ].each do |event|
      assert_equal [ due, "app", nil, nil ], [ event.effective_at, event.actor_kind, event.actor_id, event.command_id ]
    end
    assert_nil closed.cause_id
    assert hold.reload.closed_at
    step = TaskStep.find_by!(task_id: task.id, closed_at: nil)
    assert_equal [ "wait_ready", "credential_limit", closed.id ], step.values_at(:kind, :cause_kind, :opening_event_id)
  end

  test "with no hold open, task.lease_expired carries the wait_cause (HE-35)" do
    scenario, task, = limited_builder_task(hold: false)
    scenario.make_due(task)

    timer_in(scenario, "task_id" => task.id)

    expired = Event.where(task_id: task.id, type: "task.lease_expired").sole
    assert_equal({ "wait_cause" => "credential_limit" }, expired.payload)
    assert_equal [ "wait_ready", "credential_limit" ], TaskStep.find_by!(task_id: task.id, closed_at: nil).values_at(:kind, :cause_kind)
  end
end
