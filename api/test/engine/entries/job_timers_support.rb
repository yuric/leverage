require_relative "call_spy"

# What the tests of milestone 4's timers share (its plan, WP7): the four
# job timers and orchestrator_offline call writers that other packages
# own (Jobs is WP6's, RuleChecks and PendingTransitions are WP4's) and that
# do nothing yet in this package's worktree. with_writers puts in their
# place stand-ins that write what the contract says the real ones write
# (timers.json, state_machine.json, trace 07), each with the context's own
# defaults: the actor, the key and the effective time of the context they
# are given, and that time for the rows they change. So a test proves what
# the timers call, in which order, and in which context (the app, no key,
# the due time), and a trace's events come out as the trace has them. What
# the finished writers do is their packages' tests, and both together are
# WP12's (the whole traces).
#
# Every value is made up.
module JobTimersSupport
  include CallSpy

  T = Leverage::Transitions

  # The writers a timer calls, and their stand-ins below.
  WRITERS = {
    Leverage::Jobs => %i[time_out requeue queue],
    Leverage::RuleChecks => %i[error new_attempt],
    Leverage::PendingTransitions => %i[reenter]
  }.freeze

  # A call to a writer: which one, and its arguments.
  Call = Data.define(:name, :arguments, :keywords)

  # Runs the block with the stand-in writers; returns the calls, in order.
  def with_writers
    calls = []
    saved = WRITERS.flat_map { |mod, names| names.map { |name| [ mod, name, mod.method(name) ] } }
    WRITERS.each do |mod, names|
      names.each do |name|
        stand_in = Writers.method(name)
        mod.define_singleton_method(name) do |*arguments, **keywords|
          calls << Call.new(name: "#{mod.name.demodulize}.#{name}", arguments: arguments, keywords: keywords)
          stand_in.call(*arguments, **keywords)
        end
      end
    end
    yield
    calls
  ensure
    saved&.each { |mod, name, original| mod.define_singleton_method(name, original) }
  end

  # The stand-ins. Each writes what the contract's rows say its writer
  # writes, with the context's defaults, so the event's actor, key and
  # effective time are those of the context the timer gave it.
  module Writers
    module_function

    def task_of(row) = row.task_id && Task.find(row.task_id)

    # job.timed_out on the job (timers.json).
    def time_out(ctx, job, _kind)
      job.update!(state: "timed_out", finished_at: ctx.effective_at)
      ctx.emit("job.timed_out", task: task_of(job), subject: job, payload: {})
    end

    # job.requeued on the old job; the new one is queued at the context's
    # effective time and writes no job.queued (DB-31, trace 07).
    def requeue(ctx, job)
      fresh = Job.create!(workspace_id: job.workspace_id, kind: job.kind, task_id: job.task_id, project_id: job.project_id,
        target_kind: job.target_kind, target_id: job.target_id, seat_role: job.seat_role, state: "queued",
        queued_at: ctx.effective_at, input: job.input, attempt_number: job.attempt_number + 1)
      ctx.emit("job.requeued", task: task_of(job), subject: job, payload: {})
      fresh
    end

    # attempt_number: the attempt a rule check's job runs (Jobs.queue's
    # optional keyword).
    def queue(ctx, kind:, task:, target:, seat_role:, input:, attempt_number: 1)
      job = Job.create!(workspace_id: ctx.workspace.id, kind: kind, task_id: task&.id, project_id: task&.project_id,
        target_kind: Leverage::EventLog.kind_of(target), target_id: target.id, seat_role: seat_role, state: "queued",
        queued_at: ctx.effective_at, input: input, attempt_number: attempt_number)
      ctx.emit("job.queued", task: task, subject: job, payload: { kind: kind })
      job
    end

    # check.finished with the result error (L399).
    def error(ctx, check)
      RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last&.update!(finished_at: ctx.effective_at)
      check.update!(result: "error")
      ctx.emit("check.finished", task: task_of(check), subject: check,
        payload: identity(check).merge(result: "error", effect: nil, wait_cause: nil))
    end

    # check.queued for a new attempt run by job (DB-25: the result is null
    # until it finishes).
    def new_attempt(ctx, check, job:)
      number = RuleCheckAttempt.where(rule_check_id: check.id).maximum(:attempt_number).to_i + 1
      attempt = RuleCheckAttempt.create!(workspace_id: check.workspace_id, rule_check_id: check.id, attempt_number: number,
        job_id: job.id, queued_at: job.queued_at)
      check.update!(result: nil)
      blocking = RuleVersion.find(check.rule_version_id).on_fail != "warn"
      ctx.emit("check.queued", task: task_of(check), subject: check,
        payload: identity(check).merge(attempt_number: number, job_id: job.id, blocking: blocking, claimant_seat_id: nil,
          pending_transition_id: check.pending_transition_id, action_id: nil))
      attempt
    end

    # Rule 9 and 10 of the plan's §2.1, for an errored blocking check: the
    # transition stays pending under check_error, whose item opens only
    # while the orchestrator is online (SM-39). The hold's cause is the
    # check.finished that ended it (trace 07).
    def reenter(ctx, pending, trigger)
      return nil unless trigger.kind == :check_timed_out

      check = RuleCheck.find(trigger.rule_check_id)
      finished = ctx.events.reverse.find { |event| event.type == "check.finished" && event.subject_id == check.id }
      Leverage::Holds.open(ctx, task: Task.find(pending.task_id), reason: "check_error", rule_id: check.rule_id,
        cause_id: finished&.id, facts: { rule_id: check.rule_id, rule_check_id: check.id },
        item: Leverage::RolePresence.online?(ctx.workspace, "orchestrator", ctx.at))
      nil
    end

    def identity(check)
      { hook: check.hook, rule_id: check.rule_id, rule_version_id: check.rule_version_id, subject_kind: check.subject_kind,
        subject_id: check.subject_id, input_hash: check.input_hash }
    end
  end

  # --- building the state -----------------------------------------------------

  # A Backlog task whose Complete contract waits on a model check of the
  # shipped specific_details rule (trace 07's command 2): the pending
  # transition, the check row with its attempts and their jobs (the last one
  # queued, or claimed by checker when started), as Scenario writes them.
  # Returns [task, check, pending].
  def pending_check(rule: nil, attempts: 1, started: false, checker: nil, hook: nil, task_state: "backlog",
                    command: "complete_contract")
    rule ||= (@specific_details ||= scenario.rule(key: "specific_details", origin: "shipped"))
    task = scenario.task(state: task_state)
    pending = scenario.pending_transition(task, command: command, requester: scenario.owner, params: { "id" => task.id })
    check = scenario.rule_check(task, rule: rule, attempts: attempts, started: started, checker: checker, hook: hook,
      pending: pending)
    [ task, check, pending ]
  end

  # The latest attempt of a check, and its job.
  def latest_attempt(check) = RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last

  def job_of(check) = Job.find(latest_attempt(check).job_id)

  # Puts a check's latest attempt at its queue due time now (EN-18: no test
  # waits): queued that many seconds before the database's now, so its due
  # time is the now, which comes after every event Scenario has written.
  # Returns the due time.
  def make_queue_due(check, timeout: 120)
    due = scenario.database_now
    latest_attempt(check).update_columns(queued_at: due - timeout)
    job_of(check).update_columns(queued_at: due - timeout)
    due
  end

  # The same for a started attempt's run due time.
  def make_run_due(check, timeout: 300)
    due = scenario.database_now
    latest_attempt(check).update_columns(started_at: due - timeout)
    job_of(check).update_columns(claimed_at: due - timeout)
    due
  end

  # A job of its own (a contract draft's) put at its queue or run due time.
  def make_job_due(job, kind, timeout: kind == :queue ? 120 : 300)
    due = scenario.database_now
    job.update_columns(kind == :queue ? { queued_at: due - timeout } : { claimed_at: due - timeout })
    due
  end

  # An orchestrator seat that connects on its own (no credential) and last
  # polled seconds_ago before the database's now (nil: never).
  def orchestrator_polled(seconds_ago, **options)
    seat = scenario.orchestrator(**options)
    seat.update_columns(last_polled_at: seconds_ago && scenario.database_now - seconds_ago)
    seat
  end

  # --- running a timer --------------------------------------------------------

  # Runs a timer as the sweep runs it (Sweep.timer): by the app, no key, no
  # commands row; params job_id names one job, none takes the due ones.
  def timer(command, params = {})
    T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: nil, caller_id: nil, key: nil,
      request_hash: nil, params: params))
  end

  def last_seq = Workspace.find(scenario.workspace_id).last_seq

  # The jobs a job timer's run says it timed out (its result), or nil.
  def timed_out(outcome) = outcome.result.to_h["timed_out_job_ids"]

  def events_after(seq) = Event.where(workspace_id: scenario.workspace_id).where("seq > ?", seq).order(:seq).to_a

  # Whether two times are the same instant, to the microsecond PostgreSQL
  # keeps.
  def assert_instant(expected, actual, message = nil)
    assert_in_delta expected.to_f, actual.to_f, 0.000_001, message
  end

  # Every event of a timer: written by the app, with no key, effective at
  # the given time, at the command's own clock.
  def assert_by_app_at(events, effective_at)
    refute_empty events
    events.each do |event|
      assert_equal [ "app", nil, nil ], [ event.actor_kind, event.actor_id, event.command_id ], event.type
      assert_instant effective_at, event.effective_at, "#{event.type} is effective at the due time"
    end
    assert_equal [ events.first.at ], events.map(&:at).uniq, "one command, one clock"
  end
end
