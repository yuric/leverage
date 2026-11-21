require "test_helper"

# Leverage::Steps, the step tracker (PRD L269-L306; steps.json; milestone 2
# plan WP4, EN-10, EN-11, EN-13, EN-27, EN-30, EN-31). EventLog.append
# calls Steps.on_event for every event it inserts, and the tracker opens and
# closes the task's steps in the same call, from the events alone.
#
# The trace tests feed each golden trace's expected events through EventLog,
# one context per command, and compare the steps they leave with the
# trace's steps_opened and steps_closed, field for field. A row is compared
# as it was when it opened: the criterion back-fill (rule 5) later gives an
# open build row its criterion, which a trace cannot show (TS8-check), so
# the back-fill has a test of its own.
class StepTrackerTest < ActiveSupport::TestCase
  START = Time.utc(2026, 11, 19, 9, 0, 0)

  setup do
    @binder = Leverage::Contract::TraceBinder.new(start: START)
    @bound_to_real = {}
  end

  # Feeds one golden trace's expected events through EventLog, one context
  # per command, and checks every command's steps. Yields each command's
  # number after its check. Returns the task's id.
  def feed(name)
    trace = @binder.bind(Leverage::Contract.trace(name))
    @scenario = Scenario.new.seed(trace.fetch("setup"))
    @bodies = {}
    trace.fetch("commands").each_with_index do |command, index|
      expect = command.fetch("expect")
      @bodies[command["key"]] = command.fetch("body") if command["key"]
      rows_for(command)
      normalize_first_action_check(expect) if name == "04-two-actions-custom-rule" && index == 15
      ids = ActiveRecord::Base.transaction(requires_new: true) do
        ctx = @scenario.context(at: Time.iso8601(command.fetch("at")))
        expect.fetch("events").map { |event| append_expected(ctx, event).id }
      end
      check_command("#{name} command #{index + 1} (#{command.fetch("command")})", expect, ids)
      yield(index + 1, ids) if block_given?
    end
    Event.find(@bound_to_real.values.first).task_id
  end

  # WP12 updates this trace's frozen references. steps.json opens check on
  # the first blocking check queued. Trace 04 currently points to the send
  # approval even though the earlier publish gate starts the check step.
  def normalize_first_action_check(expect)
    opened = expect.fetch("steps_opened").first
    closed = expect.fetch("steps_closed").first
    queues = expect.fetch("events").select { |event| event["type"] == "check.queued" && event.dig("payload", "blocking") }
    assert_equal 2, queues.size
    first_queue, later_queue = queues
    first_ref = first_queue.fetch("ref")
    later_ref = later_queue.fetch("ref")
    assert_equal first_queue.dig("payload", "action_id"), opened.fetch("subject_id")
    assert_not_equal later_queue.dig("payload", "action_id"), opened.fetch("subject_id")
    return if [ opened["opening_event_id"], closed["closing_event_id"] ] == [ first_ref, first_ref ]

    assert_equal [ later_ref, later_ref ], [ opened["opening_event_id"], closed["closing_event_id"] ]
    opened["opening_event_id"] = closed["closing_event_id"] = first_ref
  end

  # The rows a trace's events are about that a command's entry would make:
  # the task, the contract's criteria with their kinds, and the jobs with
  # theirs (a job.claimed opens draft only for a contract draft's job). A
  # contract a pending transition completes is the request of the command
  # whose key its events carry (milestone 4 plan RE-2, RE-3), and a
  # planner's is the result of its job (RE-6).
  def rows_for(command)
    command.fetch("expect").fetch("events").each do |event|
      case event.fetch("type")
      when "task.created"
        Task.create!(id: event.fetch("task_id"), workspace_id: @scenario.workspace_id,
          state: event.dig("payload", "state"))
      when "task.contract_changed"
        body = @bodies.fetch(event.fetch("command_id"))
        kinds = (body["criteria"] || body.fetch("result").fetch("criteria")).map { |criterion| criterion.fetch("kind") }
        event.dig("payload", "added_criterion_ids").each_with_index do |id, position|
          Criterion.create!(id: id, workspace_id: @scenario.workspace_id, task_id: event.fetch("task_id"),
            position: position + 1, kind: kinds.fetch(position), text: "Made-up criterion #{position + 1}.")
        end
      when "job.queued"
        job_row(event.fetch("subject_id"), event.dig("payload", "kind"), event)
      when "check.queued"
        job_row(event.dig("payload", "job_id"), "rule_check", event)
      end
    end
  end

  def job_row(id, kind, event)
    return if Job.exists?(id: id)

    Job.create!(id: id, workspace_id: @scenario.workspace_id, kind: kind, task_id: event.fetch("task_id"),
      target_kind: kind == "rule_check" ? "rule_check" : "task",
      target_id: kind == "rule_check" ? event.fetch("subject_id") : event.fetch("task_id"),
      seat_role: kind == "contract_draft" ? "planner" : "orchestrator", queued_at: Time.iso8601(event.fetch("at")),
      input: {})
  end

  # Appends one expected event; EventLog gives it a new id, remembered
  # under the bound @event:n id the trace names it by.
  def append_expected(ctx, event)
    cause = event.fetch("cause_id")
    Leverage::EventLog.append(ctx, type: event.fetch("type"), payload: event.fetch("payload"),
      task_id: event.fetch("task_id"), project_id: event.fetch("project_id"), round: event.fetch("round"),
      subject_kind: event.fetch("subject_kind"), subject_id: event.fetch("subject_id"),
      cause_id: cause && @bound_to_real.fetch(cause), actor_kind: event.fetch("actor_kind"),
      actor_id: event.fetch("actor_id"), command_id: event.fetch("command_id"),
      effective_at: Time.iso8601(event.fetch("effective_at")))
      .tap { |appended| @bound_to_real[event.fetch("ref")] = appended.id }
  end

  def check_command(label, expect, ids)
    closed = TaskStep.where(closing_event_id: ids).order(:closed_at, :created_at)
    opened = TaskStep.where(opening_event_id: ids).order(:opened_at, :created_at)

    assert_equal expect.fetch("steps_closed").map { |step| closed_fields(step) },
      closed.map { |row| [ row.task_id, row.kind, row.closing_event_id ] }, "#{label}: steps closed"
    assert_equal expect.fetch("steps_opened").map { |step| opened_fields(step) },
      opened.map { |row| opened_row(row) }, "#{label}: steps opened"
    opened.each do |row|
      assert_equal Event.find(row.opening_event_id).effective_at, row.opened_at, "#{label}: opens at its event's time"
    end
    closed.each do |row|
      assert_equal Event.find(row.closing_event_id).effective_at, row.closed_at, "#{label}: closes at its event's time"
    end
    TaskStep.where(workspace_id: @scenario.workspace_id).distinct.pluck(:task_id).each do |task_id|
      assert_operator TaskStep.where(task_id: task_id, closed_at: nil).count, :<=, 1, "#{label}: one open step per task"
    end
  end

  def closed_fields(step)
    [ step.fetch("task_id"), step.fetch("kind"), @bound_to_real.fetch(step.fetch("closing_event_id")) ]
  end

  def opened_fields(step)
    step.values_at("task_id", "kind", "step_class", "round", "subject_kind", "subject_id", "seat_id", "cause_kind",
      "cause_rule_id") + [ @bound_to_real.fetch(step.fetch("opening_event_id")) ]
  end

  def opened_row(row)
    [ row.task_id, row.kind, row.step_class, row.round, row.subject_kind, row.subject_id, row.seat_id, row.cause_kind,
      row.cause_rule_id, row.opening_event_id ]
  end

  # --- The golden traces -----------------------------------------------

  test "trace 09's events yield exactly its steps, and the task's steps sum to its lifetime" do
    task_id = feed("09-core-loop-no-rules")
    assert_lifetime(task_id)
    assert_equal 0, TaskStep.where(task_id: task_id, closed_at: nil).count, "a done task has no open step"
  end

  test "trace 10's events yield exactly its steps, and the task's steps sum to its lifetime" do
    task_id = feed("10-leases-no-rules")
    assert_lifetime(task_id)
    assert_equal 0, TaskStep.where(task_id: task_id, closed_at: nil).count, "a cancelled task has no open step"
  end

  # Milestone 3 (plan WP4): the handoff's traces. Each has several tasks;
  # every one of them is checked command by command, and each task that
  # has ended has steps that sum to its lifetime.
  {
    "11-limit-handoff-no-rules" => "wait_limit with the candidate that resets first, then build again",
    "12-signed-out-hold-verify-no-rules" => "wait_owner for credential_signed_out",
    "13-limit-next-signed-out-no-rules" => "wait_owner for a limit whose next candidate is signed out",
    "14-handoff-edges-no-rules" => "wait_limit, and wait_ready with the cause credential_limit at hold.closed",
    "15-owner-controls-no-rules" => "idea, wait_seat for a paused seat, wait_owner for owner_hold"
  }.each do |name, what|
    test "trace #{name[0, 2]}'s events yield exactly its steps: #{what}" do
      feed(name)
      ended = TaskStep.where(workspace_id: @scenario.workspace_id).distinct.pluck(:task_id)
        .reject { |task_id| TaskStep.where(task_id: task_id, closed_at: nil).exists? }
      assert_not_empty ended
      ended.each { |task_id| assert_lifetime(task_id) }
    end
  end

  # Milestone 4 (its plan, WP5): the rule checks' traces, row for row. The
  # commands that write their events are other packages'; here the events
  # alone drive the tracker: check opens at a pending transition's first
  # blocking check.queued and closes where the transition ends, and draft
  # is a planner's claimed job. Trace 19 is not fed here: its rules come
  # from install_shipped_rules, whose rule rows the feed does not make. It
  # runs whole, steps included, in golden_traces_test.rb, and the
  # wait_review cause it shows (RD-11) has a test of its own below.
  {
    "07-pending-gate-check-error-override" => "check under a pending move to Ready, wait_owner for check_error",
    "16-model-gate-and-draft" => "check, contract_incomplete's new wait_contract row, and draft",
    "17-submit-rule-rerun-and-override" => "a refused submit back to finish, rerun_limit, a warn check with no step",
    "18-claim-gate-done-gate-and-ends" => "provisional claims, the claim gate, the done gate, and waits ended from outside"
  }.each do |name, what|
    test "trace #{name[0, 2]}'s events yield exactly its steps: #{what}" do
      feed(name)
      ended = TaskStep.where(workspace_id: @scenario.workspace_id).distinct.pluck(:task_id)
        .reject { |task_id| TaskStep.where(task_id: task_id, closed_at: nil).exists? }
      ended.each { |task_id| assert_lifetime(task_id) }
    end
  end

  {
    "03-stop-rework-pass-approve-done" => "action check, stopped action, rework, wait_builder and finish",
    "04-two-actions-custom-rule" => "action checks, builder busy, and finish moving to the next action",
    "22-finishing-edges" => "holds, reoffered leases, waives, and action expiry"
  }.each do |name, what|
    test "trace #{name[0, 2]}'s events yield exactly its steps: #{what}" do
      feed(name)
    end
  end

  test "trace 18: a waiting command ended from outside closes check where the transition ends, with no step between" do
    feed("18-claim-gate-done-gate-and-ends") do |number, ids|
      next unless [ 11, 36, 46, 51 ].include?(number)

      closed = TaskStep.find_by!(kind: "check", closing_event_id: ids)
      expected = { 11 => "task.released", 36 => "task.lease_expired", 46 => "check.finished", 51 => "task.cancelled" }
      assert_equal expected.fetch(number), Event.find(closed.closing_event_id).type
      assert_equal (number == 51 ? 0 : 1), TaskStep.where(opening_event_id: ids).count,
        "the command changes the open step once (steps.json, derived rule)"
    end
  end

  test "trace 11: wait_limit names the credential the hold names and the seat that holds the task" do
    feed("11-limit-handoff-no-rules") do |number, ids|
      next unless number == 9

      step = TaskStep.find_by!(opening_event_id: ids, kind: "wait_limit")
      hold_opened = Event.find(step.opening_event_id)
      assert_equal [ "hold.opened", "credential", hold_opened.payload.fetch("credential_id") ],
        [ hold_opened.type, step.subject_kind, step.subject_id ]
      assert_equal @binder.id("$seat:builder"), step.seat_id, "the seat responsible holds the task (L278, rule 4)"
    end
  end

  test "trace 14: the lease ending under credential_limit opens wait_ready at hold.closed with its cause" do
    feed("14-handoff-edges-no-rules") do |number, ids|
      next unless number == 32

      step = TaskStep.find_by!(opening_event_id: ids)
      assert_equal [ "wait_ready", "credential_limit", "hold.closed" ],
        [ step.kind, step.cause_kind, Event.find(step.opening_event_id).type ]
    end
  end

  test "trace 10: the build row opened with no criterion is given the criterion that passes (rule 5)" do
    feed("10-leases-no-rules") do |number|
      next unless number == 12

      backfilled = TaskStep.find_by!(closing_event_id: @bound_to_real.fetch(@binder.event_id(12)))
      assert_equal [ "build", "criterion", @binder.id("$criterion:t1_copy") ],
        [ backfilled.kind, backfilled.subject_kind, backfilled.subject_id ]
    end
  end

  # --- The rules, one at a time ------------------------------------------

  test "exactly one step is open from creation, and opening a step closes the one before at the same time" do
    @scenario = Scenario.new
    task = @scenario.task(state: "working")
    rows = TaskStep.where(task_id: task.id).order(:opened_at)

    assert_equal %w[wait_contract wait_ready briefing], rows.map(&:kind)
    assert_equal 1, rows.where(closed_at: nil).count
    rows.each_cons(2) do |before, after|
      assert_equal after.opened_at, before.closed_at, "#{before.kind} closes when #{after.kind} opens"
      assert_equal after.opening_event_id, before.closing_event_id
    end
  end

  test "a step of zero length is allowed (EN-11)" do
    @scenario = Scenario.new
    task = @scenario.task(state: "backlog")
    at = TaskStep.find_by!(task_id: task.id, closed_at: nil).opened_at
    in_context(at: at, key: "k-zero") { |ctx| ctx.emit("task.cancelled", task: task, actor_kind: "owner", actor_id: @scenario.owner.id) }

    row = TaskStep.find_by!(task_id: task.id)
    assert_equal row.opened_at, row.closed_at
  end

  test "task.cancelled closes the open step and opens none (EN-30)" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder)
    cancelled = in_context(key: "k-cancel") do |ctx|
      ctx.emit("task.cancelled", task: task, actor_kind: "owner", actor_id: @scenario.owner.id)
    end

    assert_equal 0, TaskStep.where(task_id: task.id, closed_at: nil).count
    last = TaskStep.where(task_id: task.id).order(:closed_at).last
    assert_equal [ "briefing", cancelled.id ], [ last.kind, last.closing_event_id ]
    assert_nil TaskStep.find_by(opening_event_id: cancelled.id)
  end

  test "an event after the task is done or cancelled opens no step" do
    @scenario = Scenario.new
    task = @scenario.task(state: "cancelled")
    count = TaskStep.where(task_id: task.id).count
    hold = Hold.create!(workspace_id: task.workspace_id, task_id: task.id, reason: "owner_hold", opened_at: Time.current,
      opened_by_kind: "owner")
    in_context(key: "k-late") do |ctx|
      ctx.emit("hold.opened", task: task, subject: hold, payload: { reason: "owner_hold", rule_id: nil, credential_id: nil, rule_check_id: nil })
    end

    assert_equal count, TaskStep.where(task_id: task.id).count
  end

  test "the builder's acknowledgement opens build while a criterion is open, and finish when every one has passed" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    open_task = @scenario.task(state: "working", builder: builder)
    acknowledge(open_task, builder)
    assert_equal "build", open_step(open_task).kind

    other = @scenario.seat(role: "builder")
    passed_task = @scenario.task(state: "working", builder: other, criteria: %w[build review])
    Criterion.where(task_id: passed_task.id, kind: "build").find_each do |criterion|
      @scenario.append("criterion.passed", task: passed_task, subject: criterion, actor_kind: "seat", actor_id: other.id)
    end
    acknowledge(passed_task, other)
    assert_equal "finish", open_step(passed_task).kind
  end

  test "announcing a criterion opens a new build row with it; the last builder criterion passing opens finish" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder, criteria: %w[build build review])
    acknowledge(task, builder)
    first, second = Criterion.where(task_id: task.id, kind: "build").order(:position).to_a

    seat_event("criterion.started", task, builder, subject: first)
    assert_equal [ "build", first.id ], open_step(task).values_at(:kind, :subject_id)
    seat_event("criterion.started", task, builder, subject: first)
    assert_equal [ 2, 1 ], [ TaskStep.where(task_id: task.id, kind: "build", subject_id: first.id).count,
                             TaskStep.where(task_id: task.id, closed_at: nil).count ],
      "announcing the same criterion again in a later command opens a new row (SM-25; milestone 3 plan HD-9)"

    seat_event("criterion.passed", task, builder, subject: first)
    assert_equal [ "build", first.id ], open_step(task).values_at(:kind, :subject_id), "one criterion is still open"
    seat_event("criterion.started", task, builder, subject: second)
    seat_event("criterion.passed", task, builder, subject: second)
    assert_equal [ "finish", nil, builder.id ], open_step(task).values_at(:kind, :subject_id, :seat_id)
  end

  test "the criterion back-fill: an open build row with none, of the same seat and round, is given the one that passes" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    other = @scenario.seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder, criteria: %w[build build review])
    acknowledge(task, builder)
    first, second = Criterion.where(task_id: task.id, kind: "build").order(:position).to_a
    build = open_step(task)

    seat_event("criterion.passed", task, other, subject: first)
    assert_nil build.reload.subject_id, "another seat's pass gives the row nothing"
    seat_event("criterion.passed", task, builder, subject: first, round: 1)
    assert_nil build.reload.subject_id, "a pass in another round gives the row nothing"

    seat_event("criterion.passed", task, builder, subject: first)
    assert_equal [ "criterion", first.id, nil ], [ build.reload.subject_kind, build.subject_id, build.closed_at ],
      "the row stays open, now with the criterion"
    assert_equal 1, TaskStep.where(task_id: task.id, kind: "build").count, "the back-fill opens no new row"

    seat_event("criterion.started", task, builder, subject: second)
    seat_event("criterion.passed", task, builder, subject: second)
    assert_equal second.id, TaskStep.where(task_id: task.id, kind: "build").order(:opened_at).last.subject_id
  end

  test "during rework, starting and passing a criterion open no step (EN-10)" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review", builder: builder)
    review = @scenario.review(task, reviewer: reviewer)
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    seat_event("review.failed", task, reviewer, subject: review,
      payload: { failed_criterion_ids: [ criterion.id ], failed_rule_check_id: nil, lease_seat_id: builder.id, wait_cause: nil })
    assert_equal [ "wait_builder", review.id, builder.id, 1 ], open_step(task).values_at(:kind, :subject_id, :seat_id, :round)

    seat_event("task.briefing_acknowledged", task, builder, round: 1)
    rework = open_step(task)
    assert_equal [ "rework", review.id ], [ rework.kind, rework.subject_id ]
    seat_event("criterion.started", task, builder, subject: criterion, round: 1)
    seat_event("criterion.passed", task, builder, subject: criterion, round: 1)
    assert_equal rework.id, open_step(task).id
  end

  test "the reviewer's acknowledgement opens no step (EN-27), and review's subject is the review criterion" do
    @scenario = Scenario.new
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    step = open_step(task)
    assert_equal [ "review", "criterion", Criterion.find_by!(task_id: task.id, kind: "review").id, reviewer.id ],
      step.values_at(:kind, :subject_kind, :subject_id, :seat_id)

    seat_event("task.briefing_acknowledged", task, reviewer, subject: review)
    assert_equal step.id, open_step(task).id
  end

  test "a failed review with no fresh lease opens wait_ready in the new round" do
    @scenario = Scenario.new
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    seat_event("review.failed", task, reviewer, subject: review,
      payload: { failed_criterion_ids: [], failed_rule_check_id: nil, lease_seat_id: nil, wait_cause: nil })

    assert_equal [ "wait_ready", 1, nil ], open_step(task).values_at(:kind, :round, :seat_id)
  end

  # --- Holds interrupt the step ------------------------------------------

  test "a hold interrupts the work step; a newer hold changes nothing; the oldest open hold names the step" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder)
    acknowledge(task, builder)
    first = open_hold(task, "owner_hold")
    assert_equal [ "wait_owner", "waiting", "hold", first.id, nil ],
      open_step(task).values_at(:kind, :step_class, :subject_kind, :subject_id, :seat_id)

    held = open_step(task)
    second = open_hold(task, "rounds_exceeded")
    assert_equal held.id, open_step(task).id, "the oldest open hold has not changed"

    close_hold(task, first)
    assert_equal [ "wait_owner", second.id ], open_step(task).values_at(:kind, :subject_id),
      "the oldest open hold changed, so a new waiting step opens for it"
    assert_not_nil held.reload.closed_at
  end

  test "when the last hold lifts, the step the task's state calls for opens, which may differ from the one interrupted" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder)
    acknowledge(task, builder)
    hold = open_hold(task, "owner_hold")
    close_hold(task, hold)
    assert_equal [ "build", builder.id ], open_step(task).values_at(:kind, :seat_id), "the work resumes where it was"

    hold = open_hold(task, "owner_hold")
    seat_event("task.released", task, builder, payload: { reason: "unable_to_continue", wait_cause: nil })
    assert_equal "wait_owner", open_step(task).kind, "a release under a hold leaves the waiting step open"
    close_hold(task, hold)
    assert_equal [ "wait_ready", nil ], open_step(task).values_at(:kind, :seat_id)
  end

  test "within one command the open step changes at most once: a failed review at the round limit opens wait_owner" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review", builder: builder)
    review = @scenario.review(task, reviewer: reviewer)
    before = TaskStep.where(task_id: task.id).count
    hold = Hold.create!(workspace_id: task.workspace_id, task_id: task.id, reason: "rounds_exceeded", opened_at: Time.current,
      opened_by_kind: "app")
    failed, opened = in_context(key: "k-verdict", caller: [ "seat", reviewer.id ]) do |ctx|
      [ ctx.emit("review.failed", task: task, subject: review,
          payload: { failed_criterion_ids: [], failed_rule_check_id: nil, lease_seat_id: builder.id, wait_cause: nil }),
        ctx.emit("hold.opened", task: task, subject: hold, actor_kind: "app", actor_id: nil,
          payload: { reason: "rounds_exceeded", rule_id: nil, credential_id: nil, rule_check_id: nil }) ]
    end

    assert_equal before + 1, TaskStep.where(task_id: task.id).count, "one row closes and one opens"
    assert_equal failed.id, TaskStep.find_by!(task_id: task.id, kind: "review").closing_event_id
    assert_equal [ "wait_owner", opened.id, 1 ], open_step(task).values_at(:kind, :opening_event_id, :round)
  end

  # --- Rule checks and jobs (milestone 4 plan WP5; SM-24, RD-11) ---------

  test "a blocking model check opens check on its pending transition; a warn check opens no step (RC-16)" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = finishing(builder)
    finish = open_step(task)

    queue_check(task, hook: "task.before_submit", pending: nil, blocking: false, actor: builder)
    assert_equal finish.id, open_step(task).id, "a warn check is not a step (steps.json, derived rule 4)"

    pending = SecureRandom.uuid
    queued = queue_check(task, hook: "task.before_submit", pending: pending, actor: builder)
    assert_equal [ "check", "rule_check", "pending_transition", pending, nil, queued.id ],
      open_step(task).values_at(:kind, :step_class, :subject_kind, :subject_id, :seat_id, :opening_event_id)
    assert_equal queued.id, finish.reload.closing_event_id

    check = open_step(task)
    queue_check(task, hook: "task.before_submit", pending: pending, actor: builder)
    assert_equal check.id, open_step(task).id, "a second check of the same transition opens nothing"
  end

  test "a refused submit goes back to finish for the builder; a passed check alone changes nothing" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = finishing(builder)
    pending = SecureRandom.uuid
    first = queue_check(task, hook: "task.before_submit", pending: pending, actor: builder)
    second = queue_check(task, hook: "task.before_submit", pending: pending, actor: builder)
    check = open_step(task)

    finish_check(task, first, result: "passed")
    assert_equal check.id, open_step(task).id, "the other check still runs"
    failed = finish_check(task, second, result: "failed")
    assert_equal [ "finish", builder.id, failed.id ], open_step(task).values_at(:kind, :seat_id, :opening_event_id)
    assert_equal failed.id, check.reload.closing_event_id
  end

  test "an errored check keeps the transition pending, except at task.before_claim, where the claim lapses" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = finishing(builder)
    queued = queue_check(task, hook: "task.before_submit", pending: SecureRandom.uuid, actor: builder)
    check = open_step(task)
    finish_check(task, queued, result: "error")
    assert_equal check.id, open_step(task).id, "check_error's hold, which follows, is what moves the step (L392)"

    ready = @scenario.task(state: "ready")
    claim = queue_check(ready, hook: "task.before_claim", pending: SecureRandom.uuid, actor: builder,
      subject: [ "seat", builder.id ], claimant: builder)
    assert_equal "check", open_step(ready).kind
    lapsed = finish_check(ready, claim, result: "error", wait_cause: "credential_limit")
    assert_equal [ "wait_ready", "credential_limit", lapsed.id ],
      open_step(ready).values_at(:kind, :cause_kind, :opening_event_id)
  end

  test "a withdrawn check ends the transition only when no other check of it is still running" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = finishing(builder)
    pending = SecureRandom.uuid
    first = queue_check(task, hook: "task.before_submit", pending: pending, actor: builder)
    second = queue_check(task, hook: "task.before_submit", pending: pending, actor: builder)
    check = open_step(task)

    finish_check(task, first, result: "withdrawn")
    assert_equal check.id, open_step(task).id, "a rule turned off withdraws its check; the other still runs (L379)"
    finish_check(task, second, result: "withdrawn")
    assert_equal [ "finish", builder.id ], open_step(task).values_at(:kind, :seat_id)
  end

  test "a check withdrawn when its rule is turned off, then the completion in the same command: check closes there" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = finishing(builder)
    queued = queue_check(task, hook: "task.before_submit", pending: SecureRandom.uuid, actor: builder)
    check = open_step(task)
    withdrawn, submitted = in_context(key: nil) do |ctx|
      [ ctx.emit("check.finished", task: task, subject_kind: "rule_check", subject_id: queued.subject_id,
          payload: finished_payload(queued, result: "withdrawn")),
        ctx.emit("task.submitted", task: task, subject_kind: "review", subject_id: SecureRandom.uuid, actor_kind: "seat",
          actor_id: builder.id, payload: { work_reference_changed: false }) ]
    end

    assert_equal submitted.id, check.reload.closing_event_id, "check closes at the event that ends the transition"
    assert_equal [ "wait_review", submitted.id ], open_step(task).values_at(:kind, :opening_event_id)
    assert_nil TaskStep.find_by(opening_event_id: withdrawn.id), "no step opens between them"
  end

  test "a hold over a pending check makes the open step the hold's; when it lifts, check opens again on the same transition" do
    @scenario = Scenario.new
    builder = @scenario.seat(role: "builder")
    task = finishing(builder)
    pending = SecureRandom.uuid
    queue_check(task, hook: "task.before_submit", pending: pending, actor: builder)
    hold = open_hold(task, "owner_hold")
    assert_equal [ "wait_owner", hold.id ], open_step(task).values_at(:kind, :subject_id), "L378"

    close_hold(task, hold)
    assert_equal [ "check", "pending_transition", pending ], open_step(task).values_at(:kind, :subject_kind, :subject_id)
  end

  test "draft: a planner's claim of the draft job opens it; the job timing out or withdrawn reopens wait_contract (SM-24)" do
    @scenario = Scenario.new
    planner = @scenario.planner
    task = @scenario.task(state: "backlog")
    job = @scenario.job(kind: "contract_draft", task: task)
    assert_equal "wait_contract", open_step(task).kind, "queue time is wait_contract: nobody is writing it yet"

    claimed = job_event("job.claimed", task, job, planner)
    assert_equal [ "draft", "working", "job", job.id, planner.id, claimed.id ],
      open_step(task).values_at(:kind, :step_class, :subject_kind, :subject_id, :seat_id, :opening_event_id)
    timed_out = job_event("job.timed_out", task, job)
    assert_equal [ "wait_contract", timed_out.id ], open_step(task).values_at(:kind, :opening_event_id)

    again = Job.create!(workspace_id: task.workspace_id, kind: "contract_draft", task_id: task.id, target_kind: "task",
      target_id: task.id, seat_role: "planner", queued_at: @scenario.database_now, input: {}, attempt_number: 2)
    job_event("job.claimed", task, again, planner)
    assert_equal [ "draft", again.id ], open_step(task).values_at(:kind, :subject_id), "the requeued job's claim"
    withdrawn = job_event("job.withdrawn", task, again)
    assert_equal [ "wait_contract", withdrawn.id ], open_step(task).values_at(:kind, :opening_event_id)

    check_job = @scenario.job(kind: "rule_check", task: task)
    step = open_step(task)
    job_event("job.claimed", task, check_job, @scenario.orchestrator)
    assert_equal step.id, open_step(task).id, "an orchestrator's claim of a check's job is no step of its own"
  end

  test "a contract_incomplete hold opens a new wait_contract row (SM-24)" do
    @scenario = Scenario.new
    task = @scenario.task(state: "backlog")
    waiting = open_step(task)
    hold = open_hold(task, "contract_incomplete")

    assert_equal [ "wait_contract", hold.id ], [ open_step(task).kind, Event.find(open_step(task).opening_event_id).subject_id ]
    assert_not_equal waiting.id, open_step(task).id
    assert_equal open_step(task).opening_event_id, waiting.reload.closing_event_id
  end

  test "wait_review names the provider rule from its first refusal, once per wait (RD-11)" do
    @scenario = Scenario.new
    rule = @scenario.with_shipped_rules.find { |shipped| shipped.key == "different_provider_review" }
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = Review.find_by!(task_id: task.id, verdict: nil)
    waiting = open_step(task)

    refused = refuse_reviewer(task, rule, reviewer)
    assert_equal [ "wait_review", "rule", rule.id, "review", review.id, refused.id ],
      open_step(task).values_at(:kind, :cause_kind, :cause_rule_id, :subject_kind, :subject_id, :opening_event_id)
    assert_equal refused.id, waiting.reload.closing_event_id

    named = open_step(task)
    refuse_reviewer(task, rule, @scenario.seat(role: "reviewer"))
    assert_equal named.id, open_step(task).id, "a second refusal in the same wait opens nothing"

    other = @scenario.seat(role: "reviewer")
    @scenario.review(task, reviewer: other)
    seat_event("review.released", task, other, subject: review)
    assert_equal [ "wait_review", nil, nil ], open_step(task).values_at(:kind, :cause_kind, :cause_rule_id),
      "a new wait names no cause until the rule refuses again"
    refuse_reviewer(task, rule, reviewer)
    assert_equal [ "rule", rule.id ], open_step(task).values_at(:cause_kind, :cause_rule_id)
  end

  test "escalation opens the Ready wait at task.reassigned" do
    @scenario = Scenario.new
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task)
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    reassigned = in_context(key: "k-escalate", caller: [ "seat", review.reviewer_seat_id ]) do |ctx|
      ctx.emit("review.failed", task: task, subject: review,
        payload: { failed_criterion_ids: [ criterion.id ], failed_rule_check_id: nil, lease_seat_id: nil, wait_cause: nil })
      ctx.emit("task.reassigned", task: task, payload: { minimum_strength_rank: 2, wait_cause: nil })
    end

    assert_equal [ "wait_ready", 1, reassigned.id ], open_step(task).values_at(:kind, :round, :opening_event_id)
  end

  private

  def open_step(task) = TaskStep.find_by!(task_id: task.id, closed_at: nil)

  # Runs one command's emits in a context of its own, with its own key.
  def in_context(key:, at: nil, caller: [ nil, nil ], &block)
    ActiveRecord::Base.transaction(requires_new: true) do
      request = Leverage::Transitions::Request.new(command: "test", workspace_id: @scenario.workspace_id,
        caller_kind: caller.first, caller_id: caller.last, key: key, request_hash: nil, params: {})
      block.call(@scenario.context(at: at, request: request))
    end
  end

  def seat_event(type, task, seat, subject: nil, payload: {}, round: nil)
    @scenario.append(type, task: task, subject: subject, payload: payload, actor_kind: "seat", actor_id: seat.id,
      round: round)
  end

  def acknowledge(task, builder) = seat_event("task.briefing_acknowledged", task, builder)

  def open_hold(task, reason)
    hold = Hold.create!(workspace_id: task.workspace_id, task_id: task.id, reason: reason, opened_at: Time.current,
      opened_by_kind: "app")
    @scenario.append("hold.opened", task: task, subject: hold, payload: { reason: reason, rule_id: nil, credential_id: nil, rule_check_id: nil })
    hold
  end

  def close_hold(task, hold)
    hold.update!(closed_at: Time.current, closed_by_kind: "owner", closed_by_id: @scenario.owner.id)
    @scenario.append("hold.closed", task: task, subject: hold, actor_kind: "owner", actor_id: @scenario.owner.id,
      payload: { reason: hold.reason, rule_id: nil, credential_id: nil, lease_seat_id: nil, wait_cause: nil })
  end

  # A Working task whose builder criteria have all passed, acknowledged:
  # finish is open, as before a submit.
  def finishing(builder)
    task = @scenario.task(state: "working", builder: builder)
    Criterion.where(task_id: task.id, kind: "build").find_each do |criterion|
      seat_event("criterion.passed", task, builder, subject: criterion)
    end
    acknowledge(task, builder)
    assert_equal "finish", open_step(task).kind
    task
  end

  # A check.queued of a model check in a command of its own (a new rule
  # check and job, made-up ids). pending is the transition's id, or nil for
  # a warn check. Returns the Event.
  def queue_check(task, hook:, pending:, actor:, blocking: true, subject: [ nil, nil ], claimant: nil)
    @scenario.append("check.queued", task: task, actor_kind: "seat", actor_id: actor.id,
      subject: RuleCheck.new(id: SecureRandom.uuid),
      payload: { hook: hook, rule_id: SecureRandom.uuid, rule_version_id: SecureRandom.uuid, attempt_number: 1,
                 job_id: SecureRandom.uuid, blocking: blocking, claimant_seat_id: claimant&.id,
                 pending_transition_id: pending, action_id: nil, subject_kind: subject.first, subject_id: subject.last,
                 input_hash: "0" * 64 })
  end

  # The check.finished of the check a check.queued queued, by the app.
  def finish_check(task, queued, result:, wait_cause: nil)
    @scenario.append("check.finished", task: task, subject: RuleCheck.new(id: queued.subject_id),
      payload: finished_payload(queued, result: result, wait_cause: wait_cause))
  end

  def finished_payload(queued, result:, wait_cause: nil)
    queued.payload.slice("hook", "rule_id", "rule_version_id", "subject_kind", "subject_id", "input_hash")
      .merge("result" => result, "effect" => nil, "wait_cause" => wait_cause)
  end

  # The provider rule's applied row with effect refused, for a reviewer
  # claim-next skips (RC-50, RD-12).
  def refuse_reviewer(task, rule, reviewer)
    @scenario.append("check.finished", task: task, subject: RuleCheck.new(id: SecureRandom.uuid), actor_kind: "seat",
      actor_id: reviewer.id,
      payload: { hook: "review.assign", rule_id: rule.id, rule_version_id: @scenario.current_version(rule).id,
                 result: "applied", effect: "refused", wait_cause: nil, subject_kind: "seat", subject_id: reviewer.id,
                 input_hash: "0" * 64 })
  end

  # A job event on the task: by the seat when one is named, else the app.
  def job_event(type, task, job, seat = nil)
    payload = type == "job.claimed" ? { credential_id: nil, model: nil } : {}
    @scenario.append(type, task: task, subject: job, payload: payload, actor_kind: seat ? "seat" : "app",
      actor_id: seat&.id)
  end

  def assert_lifetime(task_id)
    events = Event.where(task_id: task_id).order(:seq)
    lifetime = events.last.effective_at - events.first.effective_at
    sum = TaskStep.where(task_id: task_id).sum { |row| row.closed_at - row.opened_at }
    assert_in_delta lifetime, sum, 0.000_001, "the sum of the steps is the task's lifetime (rule 6)"
  end
end
