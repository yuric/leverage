require "test_helper"
require_relative "entries/job_timers_support"

# Timers run first (PRD L118-L120, test 7 at L842, L913; milestone 2 plan
# EN-14, EN-16, EN-17, EN-18): before a command, every timer already due on
# its target task and on every task or review the calling seat holds is
# applied in the same transaction, with the due time as effective_at, the
# app as actor, no command_id, and seq before the command's own events.
# The seat's call is then refused lease_expired, and the refusal commits
# the timer's events with its commands row: no sweep has run.
#
# The seat commands here are entries defined in this file (the real ones
# are WP3's): they refuse a seat that no longer holds the task the way
# EN-15 says, through Leases.ended_by_expiry?.
module TimerTestEntries
  T = Leverage::Transitions

  # A builder's call on a task: path id is the task.
  class TaskCall < Leverage::Transitions::Entry
    def load(ctx)
      @task = Task.find_by!(id: ctx.request.params.fetch("id"), workspace_id: ctx.workspace.id)
    end

    def refusals(ctx)
      return [] if @task.holder_seat_id == ctx.request.caller_id

      [ Leverage::Leases.ended_by_expiry?(@task, ctx.request.caller_id) ? "lease_expired" : "not_holder" ]
    end

    def perform(ctx)
      Leverage::Leases.renew(ctx, @task)
      ctx.emit("cost.reported", task: @task, payload: { tokens: 1, spend: 0.01 })
      @result = { "task_id" => @task.id }
    end
  end

  # A reviewer's call on a review: path id is the review.
  class ReviewCall < Leverage::Transitions::Entry
    def load(ctx)
      @review = Review.find_by!(id: ctx.request.params.fetch("id"), workspace_id: ctx.workspace.id)
    end

    def refusals(ctx)
      return [] if @review.reviewer_seat_id == ctx.request.caller_id

      [ Leverage::Leases.ended_by_expiry?(@review, ctx.request.caller_id) ? "lease_expired" : "not_holder" ]
    end

    def perform(ctx)
      Leverage::Leases.renew(ctx, @review)
      @result = { "review_id" => @review.id }
    end
  end

  # A seat's call that names no task (a claim): only what the seat holds is
  # looked at.
  class Untargeted < Leverage::Transitions::Entry
    def perform(_ctx) = @result = {}
  end

  # Stands in for the credential_hold_release entry (WP3's), the way
  # Timers and the sweep call it (milestone 3 plan WP4): targets: inside a
  # command; params task_id or limit as the sweep's own command. It closes
  # the task's oldest credential hold when Timers says it is due, at its
  # due time, as the app, with no key.
  class HoldRelease < Leverage::Transitions::Entry
    def initialize(command = "credential_hold_release", targets: nil)
      super(command)
      @tasks = targets
    end

    def load(ctx)
      return if @tasks

      params = ctx.request.params
      @tasks = if params.key?("task_id")
        [ Task.find_by!(id: params["task_id"], workspace_id: ctx.workspace.id) ]
      else
        Leverage::Timers.due_credential_holds(ctx.workspace.id, ctx.at, %w[working], limit: Integer(params.fetch("limit", 100)))
      end
    end

    def perform(ctx)
      released = @tasks.select { |task| Leverage::Timers.credential_hold_due?(task, ctx.at) }
      released.each do |task|
        Leverage::Holds.close(ctx, hold: Leverage::Timers.credential_hold(task), task: task,
          effective_at: Leverage::Timers.credential_hold_effective_at(task), command_id: nil, actor_kind: "app", actor_id: nil)
      end
      @result = { "released_task_ids" => released.map(&:id) }
    end
  end
end

class TimersDueTest < CommittingTestCase
  T = Leverage::Transitions
  E = TimerTestEntries

  setup do
    scenario.workspace.update!(lease_length_seconds: 600)
    @builder = scenario.seat(role: "builder")
    @reviewer = scenario.seat(role: "reviewer")
  end

  def request(command, seat, key, params = {})
    T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
      key: key, request_hash: "hash-#{key}", params: params)
  end

  def apply(command, seat, key, params = {}, entry: E::TaskCall)
    T::Table.with_entries(command => entry) { T.apply(request(command, seat, key, params)) }
  end

  def events_after(seq)
    Event.where(workspace_id: scenario.workspace_id).where("seq > ?", seq).order(:seq).to_a
  end

  def last_seq = Workspace.find(scenario.workspace_id).last_seq

  test "test 7: a call after the due time is refused lease_expired, and the expiry commits at the due time" do
    task = scenario.task(state: "working", builder: @builder)
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    # The due time comes after every event the task has (effective times
    # never go backwards, L120) and before the command's time.
    due = scenario.database_now
    scenario.make_due(task, at: due)
    before = last_seq

    outcome = apply("pass_criterion", @builder, "late-pass", { "id" => task.id, "cid" => criterion.id })

    assert outcome.refused?
    assert_equal "lease_expired", outcome.refusal.code
    events = events_after(before)
    assert_equal [ "task.lease_expired" ], events.map(&:type), "the timer's event committed; the call wrote none"
    expired = events.first
    assert_in_delta due.to_f, expired.effective_at.to_f, 0.000_001, "recorded at the due time"
    assert_operator expired.at, :>, expired.effective_at
    assert_equal [ "app", nil, nil ], [ expired.actor_kind, expired.actor_id, expired.command_id ]
    assert_equal({ "wait_cause" => nil }, expired.payload)
    assert_equal task.id, expired.task_id

    task.reload
    assert_equal [ "ready", nil, nil ], [ task.state, task.holder_seat_id, task.lease_due_at ]
    assert_nil task.builder_seat_id, "back in Ready, the task has no builder (PRD, What the replay test rebuilds)"

    row = Command.find_by!(caller_kind: "seat", caller_id: @builder.id, key: "late-pass")
    assert_equal "refused", row.outcome
    assert_equal "lease_expired", row.refusal.fetch("code")
  end

  test "a repeat of the refused call is answered from its row and writes nothing" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    first = apply("heartbeat", @builder, "hb-1", { "id" => task.id })
    after_first = last_seq

    again = apply("heartbeat", @builder, "hb-1", { "id" => task.id })

    assert_equal first.refusal, again.refusal
    assert_equal after_first, last_seq
  end

  test "a heartbeat after the due time is refused and does not renew the lease" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)

    outcome = apply("heartbeat", @builder, "hb-late", { "id" => task.id })

    assert_equal "lease_expired", outcome.refusal&.code
    task.reload
    assert_nil task.lease_due_at
    assert_equal "ready", task.state
  end

  test "a call before the due time runs no timer" do
    task = scenario.task(state: "working", builder: @builder)
    before = last_seq

    outcome = apply("heartbeat", @builder, "hb-early", { "id" => task.id })

    assert outcome.completed?
    assert_equal [ "cost.reported" ], events_after(before).map(&:type)
    assert_equal "working", task.reload.state
  end

  test "a paused lease does not end, however far past its due column" do
    task = scenario.task(state: "working", builder: @builder)
    task.update_columns(lease_due_at: scenario.database_now - 3600, lease_time_left_while_paused: 300)
    before = last_seq

    outcome = apply("heartbeat", @builder, "hb-paused", { "id" => task.id })

    assert outcome.completed?
    refute_includes events_after(before).map(&:type), "task.lease_expired"
    assert_equal "working", task.reload.state
  end

  test "the timer's events come first in seq and share the command's at" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    other = scenario.seat(role: "builder")
    before = last_seq

    # Another builder's call on the task: the task's timer runs first, then
    # the call is refused (the other seat never held it).
    outcome = apply("heartbeat", other, "hb-other", { "id" => task.id })

    assert_equal "not_holder", outcome.refusal&.code
    events = events_after(before)
    assert_equal [ "task.lease_expired" ], events.map(&:type)
    assert_equal before + 1, events.first.seq
  end

  test "a timer on a task the seat holds runs before a call that names no task" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    before = last_seq

    outcome = apply("claim", @builder, "claim-1", {}, entry: E::Untargeted)

    assert outcome.completed?
    assert_equal [ "task.lease_expired" ], events_after(before).map(&:type)
    assert_equal "ready", task.reload.state
  end

  test "a reviewer's call after its review lease's due time is refused lease_expired; the task stays In review" do
    task = scenario.task(state: "in_review", builder: @builder)
    review = scenario.review(task, reviewer: @reviewer)
    due = scenario.database_now
    scenario.make_due(review, at: due)
    before = last_seq

    outcome = apply("heartbeat_review", @reviewer, "hbr-late", { "id" => review.id }, entry: E::ReviewCall)

    assert_equal "lease_expired", outcome.refusal&.code
    events = events_after(before)
    assert_equal [ "review.lease_expired" ], events.map(&:type)
    expired = events.first
    assert_in_delta due.to_f, expired.effective_at.to_f, 0.000_001
    assert_equal [ "review", review.id, task.id ], [ expired.subject_kind, expired.subject_id, expired.task_id ]
    assert_equal({}, expired.payload)
    review.reload
    assert_nil review.reviewer_seat_id, "unassigned, so another reviewer can claim it (L121)"
    assert_nil review.lease_due_at
    assert_equal "in_review", task.reload.state
  end

  test "a review the seat holds is expired before a call that names no review" do
    task = scenario.task(state: "in_review", builder: @builder)
    review = scenario.review(task, reviewer: @reviewer)
    scenario.make_due(review)
    before = last_seq

    apply("claim_review", @reviewer, "claim-review-1", {}, entry: E::Untargeted)

    assert_equal [ "review.lease_expired" ], events_after(before).map(&:type)
  end

  test "an owner's command on a task applies the task's due timer first" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    before = last_seq
    owner_request = T::Request.new(command: "cancel", workspace_id: scenario.workspace_id, caller_kind: "owner",
      caller_id: scenario.owner.id, key: "cancel-1", request_hash: "hash-cancel-1", params: { "id" => task.id })

    T::Table.with_entries("cancel" => E::Untargeted) { T.apply(owner_request) }

    assert_equal [ "task.lease_expired" ], events_after(before).map(&:type)
  end

  test "a timer on another seat's task that the call does not name is left to the sweep" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)
    other = scenario.seat(role: "builder")
    before = last_seq

    apply("claim", other, "claim-other", {}, entry: E::Untargeted)

    assert_empty events_after(before)
    assert_equal "working", task.reload.state
  end

  test "effective times never go backwards within a task" do
    task = scenario.task(state: "working", builder: @builder)
    latest = Event.where(task_id: task.id).maximum(:effective_at)
    # A due time earlier than an event the task already has: the expiry is
    # recorded at that event's time, not before it.
    scenario.make_due(task, at: latest - 60)
    before = last_seq

    apply("heartbeat", @builder, "hb-backwards", { "id" => task.id })

    expired = events_after(before).first
    assert_equal "task.lease_expired", expired.type
    assert_in_delta latest.to_f, expired.effective_at.to_f, 0.000_001
  end

  test "apply_due returns the events it wrote and leaves a timer's own command alone" do
    task = scenario.task(state: "working", builder: @builder)
    scenario.make_due(task)

    written = ActiveRecord::Base.transaction do
      ctx = scenario.context(request: request("heartbeat", @builder, "direct", { "id" => task.id }))
      Leverage::Timers.apply_due(ctx)
    end
    assert_equal [ "task.lease_expired" ], written.map(&:type)

    task2 = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    scenario.make_due(task2)
    timer_request = T::Request.new(command: "builder_lease_expiry", workspace_id: scenario.workspace_id,
      caller_kind: nil, caller_id: nil, key: nil, request_hash: nil, params: { "task_id" => task2.id })
    none = ActiveRecord::Base.transaction do
      Leverage::Timers.apply_due(scenario.context(request: timer_request))
    end
    assert_empty none, "the timer command applies itself; apply_due adds nothing"
  end
end

# The credential timer (milestone 3 plan §2.1 rule 8, HE-23, WP4): the due
# time of a task's credential hold, and test 7 for it. The timer's entry is
# HoldRelease above, standing in for WP3's.
class CredentialHoldTimerTest < CommittingTestCase
  T = Leverage::Transitions
  E = TimerTestEntries
  TM = Leverage::Timers

  setup do
    @own = scenario.limit_credential(scenario.credential, reset_at: nil)
    @builder = scenario.seat(role: "builder", credential: @own)
    @task = scenario.task(state: "working", builder: @builder)
    @hold = scenario.hold(@task, reason: "credential_limit", credential: @own, item: false)
  end

  def last_effective(task = @task) = Event.where(task_id: task.id).maximum(:effective_at)

  def last_seq = Workspace.find(scenario.workspace_id).last_seq

  def events_after(seq)
    Event.where(workspace_id: scenario.workspace_id).where("seq > ?", seq).order(:seq).to_a
  end

  def apply(caller_kind, caller_id, command, params, entry: E::Untargeted)
    request = T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: caller_kind,
      caller_id: caller_id, key: "key-#{SecureRandom.hex(4)}", request_hash: "made-up-hash", params: params)
    T::Table.with_entries(command => entry, TM::CREDENTIAL_HOLD => E::HoldRelease) { T.apply(request) }
  end

  # Puts the stopped credential's reset after every event of the task and
  # before any later command's clock: the hold is due at the reset.
  def reset_now
    reset = scenario.database_now
    @own.update!(limited_until: reset)
    reset
  end

  test "the credential hold is the task's oldest open credential hold" do
    assert_equal @hold.id, TM.credential_hold(@task).id
    other = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    assert_nil TM.credential_hold(other)
  end

  test "no reset time among the candidates: no due time (the hold has an item instead)" do
    assert_nil TM.credential_hold_due_at(@task)
    refute TM.credential_hold_due?(@task, scenario.database_now + 3600)
  end

  test "due at the earliest reset among the seat's signed-in candidates" do
    reset = scenario.database_now + 3600
    @own.update!(limited_until: reset)
    later = scenario.limit_credential(scenario.credential, reset_at: reset + 600)

    assert_equal reset, TM.credential_hold_due_at(@task)
    refute TM.credential_hold_due?(@task, reset - 1)
    assert TM.credential_hold_due?(@task, reset)

    @own.update!(state: "signed_out")
    assert_equal later.limited_until, TM.credential_hold_due_at(@task), "a signed-out candidate's reset is not one"
  end

  test "never before the task's last effective time" do
    @own.update!(limited_until: last_effective - 60)

    assert_equal last_effective, TM.credential_hold_due_at(@task)
  end

  test "at once, the task's last effective time, when a candidate is already available" do
    scenario.credential
    assert_equal last_effective, TM.credential_hold_due_at(@task)
  end

  test "the due time is read as of the task's last effective time, not the time of the look" do
    reset = reset_now

    assert_equal reset, TM.credential_hold_due_at(@task), "by the time of a later look the reset has passed"
    assert_operator reset, :>, last_effective
  end

  test "a task with no credential hold open has no due time" do
    ActiveRecord::Base.transaction(requires_new: true) { Leverage::Holds.close(scenario.context, hold: @hold, task: @task) }
    reset_now
    assert_nil TM.credential_hold_due_at(@task.reload)
  end

  test "due_credential_holds finds the due holds of a workspace, in bounded batches" do
    reset_now
    other_own = scenario.limit_credential(scenario.credential, reset_at: scenario.database_now + 3600)
    other = scenario.task(state: "working", builder: scenario.seat(role: "builder", credential: other_own))
    scenario.hold(other, reason: "credential_limit", credential: other_own, item: false)
    now = scenario.database_now

    assert_equal [ @task.id ], TM.due_credential_holds(scenario.workspace_id, now, %w[working], limit: 10).map(&:id)
    assert_empty TM.due_credential_holds(scenario.workspace_id, now, %w[ready], limit: 10)
    assert_equal 1, TM.due_credential_holds(scenario.workspace_id, now + 7200, %w[working], limit: 1).size
    assert_equal 2, TM.due_credential_holds(scenario.workspace_id, now + 7200, %w[working], limit: 5).size
  end

  # Test 7 (L842) for the credential timer: whoever calls, a command on a
  # task whose credential hold was due commits hold.closed at the due time
  # first, by the app, with no key, before the command's own events.
  {
    "a seat" => ->(test) { [ "seat", test.instance_variable_get(:@builder).id, "heartbeat", "id" ] },
    "the owner" => ->(test) { [ "owner", test.scenario.owner.id, "cancel", "id" ] },
    "the helper" => ->(test) { [ "helper", test.scenario.helper.id, "report_run_started", "task_id" ] }
  }.each do |who, call|
    test "test 7: a command by #{who} on a task whose credential hold was due closes it first, at the due time" do
      reset = reset_now
      caller_kind, caller_id, command, param = call.call(self)
      before = last_seq

      outcome = apply(caller_kind, caller_id, command, { param => @task.id })

      assert outcome.completed?, outcome.refusal&.code.to_s
      closed = events_after(before).first
      assert_equal [ "hold.closed", @hold.id, before + 1 ], [ closed.type, closed.subject_id, closed.seq ]
      assert_equal [ reset, "app", nil, nil ], [ closed.effective_at, closed.actor_kind, closed.actor_id, closed.command_id ]
      assert_operator closed.at, :>, closed.effective_at
      assert @hold.reload.closed_at
    end
  end

  test "a hold not yet due is left alone" do
    @own.update!(limited_until: scenario.database_now + 3600)
    before = last_seq

    apply("seat", @builder.id, "heartbeat", { "id" => @task.id })

    assert_empty events_after(before)
    assert_nil @hold.reload.closed_at
  end

  test "a hold due before the lease closes first; the lease's expiry follows at its own due time" do
    reset = reset_now
    lease_due = scenario.database_now
    scenario.make_due(@task, at: lease_due)
    before = last_seq

    apply("seat", @builder.id, "heartbeat", { "id" => @task.id })

    events = events_after(before)
    assert_equal %w[hold.closed task.lease_expired], events.first(2).map(&:type)
    assert_equal [ reset, lease_due ], events.first(2).map(&:effective_at)
  end

  test "a lease due before the hold ends first and its expiry closes the hold, at the lease's due time" do
    lease_due = scenario.database_now
    scenario.make_due(@task, at: lease_due)
    @own.update!(limited_until: scenario.database_now)
    before = last_seq

    apply("seat", @builder.id, "heartbeat", { "id" => @task.id })

    events = events_after(before)
    assert_equal %w[task.lease_expired hold.closed], events.map(&:type)
    assert_equal [ lease_due, lease_due ], events.map(&:effective_at)
  end

  test "apply_due leaves the two new timers' own commands alone while they are pending (HT-6)" do
    reset_now
    %w[credential_hold_release seat_run_placement].each do |command|
      request = T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: nil, caller_id: nil,
        key: nil, request_hash: nil, params: { "task_id" => @task.id })
      written = T::Table.with_entries(TM::CREDENTIAL_HOLD => E::HoldRelease) do
        ActiveRecord::Base.transaction(requires_new: true) { TM.apply_due(scenario.context(request: request)) }
      end
      assert_empty written, command
    end
  end
end

# Test 7 for the check and draft timers (PRD L118, L398, L399; milestone 4
# plan WP7): with no sweep, the timers due on a task are applied before any
# command on it, at their due times, by the app, with no key and seq before
# the command's own events, so a job past its due time is timed out before
# the command is looked at. That a late result is then refused is WP6's
# case (submit_job_result), and the two together are WP12's: here the
# command is a stand-in that refuses a result for a job that is no longer
# claimed, and the writers are JobTimersSupport's stand-ins.
class JobTimersDueTest < CommittingTestCase
  include JobTimersSupport

  E = TimerTestEntries

  # A job result: path id is the job. Refused invalid_state for a job that
  # is no longer claimed (RD-41).
  class ResultCall < Leverage::Transitions::Entry
    def load(ctx)
      @job = Job.find_by!(id: ctx.request.params.fetch("id"), workspace_id: ctx.workspace.id)
    end

    def refusals(_ctx) = @job.reload.state == "claimed" ? [] : [ "invalid_state" ]

    def perform(_ctx) = @result = {}
  end

  def seat_request(command, seat, key, params = {})
    T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id, key: key,
      request_hash: "hash-#{key}", params: params)
  end

  def owner_request(command, key, params = {})
    T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "owner",
      caller_id: scenario.owner.id, key: key, request_hash: "hash-#{key}", params: params)
  end

  def apply(request, entry)
    T::Table.with_entries(request.command => entry) { T.apply(request) }
  end

  test "test 7: a result sent after the run's due time finds its job timed out at the due time, and the miss commits" do
    orchestrator = orchestrator_polled(5)
    _task, check, = pending_check(started: true, checker: orchestrator)
    job = job_of(check)
    due = make_run_due(check)
    before = last_seq

    outcome = nil
    with_writers { outcome = apply(seat_request("submit_job_result", orchestrator, "late-result", { "id" => job.id }), ResultCall) }

    assert_equal "invalid_state", outcome.refusal&.code
    events = events_after(before)
    assert_equal %w[job.timed_out job.requeued check.queued], events.map(&:type)
    assert_by_app_at events, due
    assert_equal before + 1, events.first.seq
    assert_operator events.first.at, :>, due
    assert_equal "refused", Command.find_by!(caller_id: orchestrator.id, key: "late-result").outcome
  end

  test "a call that names a job it does not hold applies that job's due timers first all the same" do
    _task, check, = pending_check
    job = job_of(check)
    due = make_queue_due(check)
    other = orchestrator_polled(5)
    before = last_seq

    outcome = nil
    with_writers { outcome = apply(seat_request("submit_job_result", other, "not-mine", { "id" => job.id }), ResultCall) }

    assert_equal "invalid_state", outcome.refusal&.code, "the job was never claimed, and is now timed out"
    assert_equal %w[job.timed_out job.requeued check.queued], events_after(before).map(&:type)
    assert_by_app_at events_after(before), due
  end

  test "a call that names no job applies the timers of the job the calling seat holds" do
    orchestrator = orchestrator_polled(5)
    _task, check, = pending_check(started: true, checker: orchestrator)
    due = make_run_due(check)
    before = last_seq

    with_writers { apply(seat_request("claim_job", orchestrator, "claim-next"), E::Untargeted) }

    assert_by_app_at events_after(before), due
    assert_equal "timed_out", Job.find(job_of_attempt(check, 1)).state
  end

  test "the owner's command on a check applies its task's due timers first" do
    _task, check, = pending_check
    due = make_queue_due(check)
    before = last_seq

    with_writers { apply(owner_request("override_check", "override-1", { "id" => check.id }), E::Untargeted) }

    assert_equal %w[job.timed_out job.requeued check.queued], events_after(before).map(&:type)
    assert_by_app_at events_after(before), due
  end

  test "a command on a task applies its draft's due timer first" do
    task = scenario.task(state: "backlog")
    job = scenario.job(kind: "contract_draft", task: task)
    due = make_job_due(job, :queue)
    before = last_seq

    with_writers { apply(owner_request("draft_contract", "draft-1", { "id" => task.id }), E::Untargeted) }

    assert_equal %w[job.timed_out job.requeued], events_after(before).map(&:type)
    assert_by_app_at events_after(before), due
  end

  test "a job not yet due is left alone, and so is another task's" do
    _task, check, = pending_check
    _other, due_check, = pending_check
    make_queue_due(due_check)
    before = last_seq

    calls = with_writers { apply(owner_request("override_check", "override-2", { "id" => check.id }), E::Untargeted) }

    assert_empty calls
    assert_equal before, last_seq
  end

  # Effective times never go backwards within a task (L120): the timers due
  # on one task run in the order of their due times.
  test "a check that was due before its task's lease times out first" do
    task, check, = pending_check(task_state: "working", command: "submit")
    job_due = make_queue_due(check)
    lease_due = scenario.make_due(task).lease_due_at
    before = last_seq

    with_writers { apply(owner_request("hold", "hold-1", { "id" => task.id }), E::Untargeted) }

    events = events_after(before)
    assert_equal %w[job.timed_out job.requeued check.queued task.lease_expired], events.map(&:type)
    assert_equal [ job_due, job_due, job_due, lease_due ].map(&:to_f), events.map { |event| event.effective_at.to_f }
  end

  test "a lease that was due before its task's check ends first" do
    task, check, = pending_check(task_state: "working", command: "submit")
    lease_due = scenario.make_due(task).lease_due_at
    job_due = make_queue_due(check)
    before = last_seq

    with_writers { apply(owner_request("hold", "hold-2", { "id" => task.id }), E::Untargeted) }

    events = events_after(before)
    assert_equal %w[task.lease_expired job.timed_out job.requeued check.queued], events.map(&:type)
    assert_equal [ lease_due, job_due, job_due, job_due ].map(&:to_f), events.map { |event| event.effective_at.to_f }
  end

  test "before a job claim, every queued job past its queue due time is timed out; a claimed one is not" do
    orchestrator = orchestrator_polled(5)
    _task, queued, = pending_check
    queue_due = make_queue_due(queued)
    draft = scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"))
    make_job_due(draft, :queue)
    _other, running, = pending_check(started: true, checker: scenario.orchestrator)
    make_run_due(running)

    written = nil
    with_writers do
      written = ActiveRecord::Base.transaction do
        Leverage::Timers.apply_claimable(scenario.context(request: seat_request("claim_job", orchestrator, "claim")), :job)
      end
    end

    assert_equal "timed_out", Job.find(job_of_attempt(queued, 1)).state
    assert_equal "timed_out", draft.reload.state
    assert_equal "claimed", job_of(running).state, "a run timeout is the holder's, not the claim's"
    assert_instant queue_due, Event.where(workspace_id: scenario.workspace_id, type: "job.timed_out")
      .order(:seq).first.effective_at
    assert_equal %w[job.timed_out job.requeued check.queued job.timed_out job.requeued], written.map(&:type),
      "the check's job first: it was due first"
  end

  def job_of_attempt(check, number) = RuleCheckAttempt.find_by!(rule_check_id: check.id, attempt_number: number).job_id
end
