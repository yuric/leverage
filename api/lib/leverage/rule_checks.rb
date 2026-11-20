module Leverage
  # The rule checks a gate plans and what happens to them (PRD L360 to
  # L423; milestone 4 plan §2.1, RE-1, RE-7, RE-9): the only writer of
  # rule_checks and rule_check_attempts, and the only emitter of check.*.
  # A check's reason and an override's reason stay on the row (L221).
  #
  # A row is one identity (DB-25: task, rule version, hook, round, subject,
  # input hash). An app check has one attempt, queued, started and finished
  # at the command's time, and writes only check.finished (DB-30). A model
  # check has one attempt per job (DB-31, RD-44): check.queued when it is
  # queued, check.started when a seat claims its job, and check.finished
  # with its result. Running a row again (an error or a withdrawn check met
  # again by the same inputs, rule 4) adds an attempt to the same row and
  # sets its result to null until it finishes.
  #
  # Every writer takes, besides the context, the optional keywords
  # actor_kind:, actor_id:, effective_at: and command_id: (each defaulting
  # to the command's own, as EventLog.append's do), for a timer that runs
  # inside another command (milestone 4 notes, WP1's request 5).
  module RuleChecks
    # The kinds a check.queued names as its action, or its claimant.
    ACTION = "action".freeze
    CLAIM_HOOK = "task.before_claim".freeze

    module_function

    # Writes an Evaluation's checks for task, in the order of
    # evaluation.checks, under pending when the command waits (rules 5 and
    # 6): an app check's row with its one attempt and check.finished; a
    # model check's row, then, for the PlannedJob that names it, its first
    # attempt (queue_attempt); a model check the plan gives no job (the run
    # past the re-run limit, RD-45) is a row with no attempt and no event.
    #
    # Returns the RuleCheck rows in the order of evaluation.checks, so a
    # PlannedJob's rule_check_ref and a PlannedHold's index find theirs.
    def write(ctx, evaluation, task:, pending: nil, **as)
      evaluation.checks.each_with_index.map do |planned, index|
        check = row_for(ctx, planned, task: task, pending: pending)
        if planned.checker == "app" || !planned.result.nil?
          attempt(ctx, check, job: nil, started: true, finished: true, **as)
          emit_finished(ctx, check, task, **as)
        else
          job = evaluation.jobs.find { |candidate| candidate.rule_check_ref == index }
          queue_attempt(ctx, check, kind: job.kind, seat_role: job.seat_role, **as) if job
        end
        check
      end
    end

    # The attempt that job runs has started: seat claimed it
    # (check.started, by the seat). Returns the Event.
    def start(ctx, check, job:, seat:, **as)
      attempt = RuleCheckAttempt.find_by!(rule_check_id: check.id, job_id: job.id)
      attempt.update!(started_at: ctx.at, checker_seat_id: seat.id)
      emit(ctx, "check.started", check, { attempt_number: attempt.attempt_number }, **as)
    end

    # The attempt finished with a checker's result, its reason, and the
    # tokens and spend it reported (check.finished). The reason is stored
    # on the row only. Returns the Event.
    def finish(ctx, check, result:, reason:, tokens: nil, spend: nil, **as)
      check.update!(result: result, reason: reason)
      latest_attempt(check)&.update!(finished_at: ctx.at, tokens: tokens, spend: spend)
      emit_finished(ctx, check, task_of(check), **as)
    end

    # The check ends in error after its second miss (check.finished,
    # result error). Returns the Event.
    def error(ctx, check, **as)
      check.update!(result: "error")
      end_attempt(ctx, check)
      emit_finished(ctx, check, task_of(check), **as)
    end

    # The check is withdrawn: its rule was turned off or removed, or its
    # waiting command was ended (check.finished, result withdrawn). Its
    # job is the caller's to withdraw (Jobs.withdraw). Returns the Event.
    def withdraw(ctx, check, **as)
      check.update!(result: "withdrawn")
      end_attempt(ctx, check)
      emit_finished(ctx, check, task_of(check), **as)
    end

    # The owner lets the check through once, with who, when and why
    # (check.overridden, L423). The reason is stored on the row only.
    # Returns the Event.
    def override(ctx, check, user:, reason:, **as)
      check.update!(overridden_by_user_id: user.id, overridden_at: ctx.at, override_reason: reason)
      emit(ctx, "check.overridden", check, {}, **as)
    end

    # The next attempt of the check on a job of its own, in the order the
    # traces write them (07, 16 to 19): check.queued names the job, then
    # Jobs.queue makes it with that id and writes job.queued, then the
    # attempt row names it. What write does for a model check, and what a
    # re-run that queues a new job does (rerun_check, the orchestrator's
    # return; milestone 4 plan RD-42, RD-19). The job's input is RC-33's,
    # with the hook's inputs from the waiting command's stored request. The
    # row's result is null until the attempt finishes (DB-25). Returns the
    # RuleCheckAttempt.
    def queue_attempt(ctx, check, kind: "rule_check", seat_role: "orchestrator", **as)
      check.update!(result: nil, reason: nil) unless check.result.nil?
      task = task_of(check)
      number = next_attempt_number(check)
      job_id = SecureRandom.uuid
      emit_queued(ctx, check, number, job_id, **as)
      job = Jobs.queue(ctx, kind: kind, task: task, target: check, seat_role: seat_role, input: job_input(ctx, check, task, number),
        id: job_id, attempt_number: number, **as)
      attempt(ctx, check, job: job, started: false, finished: false, queued_at: job.queued_at, **as)
    end

    # A new attempt of the check, run by job, a job already made
    # (check.queued): after a miss, the timed-out job's work queued again
    # (Jobs.requeue writes no job.queued, trace 07). The row's result is
    # null until the attempt finishes (DB-25). Returns the
    # RuleCheckAttempt.
    def new_attempt(ctx, check, job:, **as)
      check.update!(result: nil, reason: nil) unless check.result.nil?
      made = attempt(ctx, check, job: job, started: false, finished: false, queued_at: job.queued_at, **as)
      emit_queued(ctx, check, made.attempt_number, job.id, **as)
      made
    end

    # The checks of a pending transition that have not settled it: no
    # result yet, or an error not overridden (which keeps it pending under
    # check_error). What a cancellation withdraws (rule 11, L367). A
    # provisional claim's errored check is kept: the claim lapses and the
    # check stays in error under its check_error hold (L392).
    def unsettled(pending)
      results = pending.command == "claim" ? [ nil ] : [ nil, "error" ]
      RuleCheck.where(workspace_id: pending.workspace_id, pending_transition_id: pending.id, overridden_at: nil)
        .where(result: results).order(:created_at, :id).to_a
    end

    # The job of the check's latest attempt that is still queued or
    # claimed, or nil.
    def open_job(check)
      job_id = latest_attempt(check)&.job_id
      job_id && Job.find_by(id: job_id, state: %w[queued claimed])
    end

    # The latest check.finished of the check, or nil.
    def last_finished(check) = last_event(check, "check.finished")

    # The latest check.overridden of the check, or nil.
    def last_overridden(check) = last_event(check, "check.overridden")

    # A check blocks its transition or action: a gate with on_fail block,
    # or the approval policy (check.queued's blocking).
    def blocking?(check)
      version = RuleVersion.find(check.rule_version_id)
      version.kind == "gate" ? version.on_fail != "warn" : check.hook == "action.requested"
    end

    # --- private -------------------------------------------------------------

    def row_for(ctx, planned, task:, pending:)
      identity = { workspace_id: ctx.workspace.id, task_id: task&.id, rule_version_id: planned.rule_version_id,
                   hook: planned.hook, round: planned.round, subject_kind: planned.subject_kind,
                   subject_id: planned.subject_id, input_hash: planned.input_hash }
      fields = { result: planned.result, effect: planned.effect, reason: planned.reason,
                 pending_transition_id: pending&.id }
      existing = RuleCheck.find_by(identity)
      return existing.tap { |row| row.update!(**fields) } if existing

      RuleCheck.create!(**identity, project_id: task&.project_id, rule_id: planned.rule_id, **fields)
    end

    def emit_queued(ctx, check, number, job_id, **as)
      emit(ctx, "check.queued", check, payload(check).merge(attempt_number: number, job_id: job_id,
        blocking: blocking?(check), claimant_seat_id: claimant(check), pending_transition_id: check.pending_transition_id,
        action_id: (check.subject_id if check.subject_kind == ACTION)), **as)
    end

    # RC-33's rule check input; the hook's inputs from the waiting
    # command's stored request (RE-2), else the command's own.
    def job_input(ctx, check, task, number)
      pending = check.pending_transition_id && PendingTransition.find_by(id: check.pending_transition_id)
      params = pending&.params || ctx.request.params
      inputs = HookInputs.for(hook: check.hook, task: task, params: params,
        seat: (Seat.find(check.subject_id) if check.subject_kind == "seat"),
        review: (Review.find(check.subject_id) if check.subject_kind == "review"))
      { rule_check_id: check.id, attempt_number: number, rule_version_id: check.rule_version_id, hook: check.hook,
        task_id: task&.id, project_id: task&.project_id, inputs: inputs }.deep_stringify_keys
    end

    def attempt(ctx, check, job:, started:, finished:, queued_at: nil, **_as)
      RuleCheckAttempt.create!(workspace_id: check.workspace_id, rule_check_id: check.id,
        attempt_number: next_attempt_number(check), job_id: job&.id, queued_at: queued_at || ctx.at,
        started_at: (ctx.at if started), finished_at: (ctx.at if finished))
    end

    def end_attempt(ctx, check)
      attempt = latest_attempt(check)
      attempt.update!(finished_at: ctx.at) if attempt && attempt.finished_at.nil?
    end

    def next_attempt_number(check)
      (RuleCheckAttempt.where(rule_check_id: check.id).maximum(:attempt_number) || 0) + 1
    end

    def latest_attempt(check)
      RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last
    end

    def emit_finished(ctx, check, task, **as)
      emit(ctx, "check.finished", check, payload(check).merge(result: check.result, effect: check.effect,
        wait_cause: wait_cause(ctx, check, task, as[:effective_at])), task: task, **as)
    end

    # The wait_ready step a check.finished opens (steps.json): when a
    # provisional claim lapses because its blocking check failed or erred.
    def wait_cause(ctx, check, task, effective_at)
      return nil unless check.hook == CLAIM_HOOK && check.pending_transition_id && %w[failed error].include?(check.result)
      return nil unless task && blocking?(check) && check.overridden_at.nil?

      Candidates.wait_cause(task, effective_at || ctx.at)
    end

    def payload(check)
      { hook: check.hook, rule_id: check.rule_id, rule_version_id: check.rule_version_id,
        subject_kind: check.subject_kind, subject_id: check.subject_id, input_hash: check.input_hash }
    end

    # At task.before_claim a waiting claim's check names the claimant: the
    # seat it is about.
    def claimant(check)
      check.subject_id if check.hook == CLAIM_HOOK && check.subject_kind == "seat" && check.pending_transition_id
    end

    def emit(ctx, type, check, body, task: task_of(check), **as)
      fields = event_fields(as)
      fields[:task] = task if task
      ctx.emit(type, subject: check, payload: body, **fields)
    end

    # The event columns a writer was given (actor_kind:, actor_id:,
    # effective_at:, command_id:), for EventLog.append: a named actor or
    # key is passed even when nil (a timer's events have none); a nil
    # effective_at means the command's own. Raises ArgumentError for any
    # other keyword.
    def event_fields(as)
      unknown = as.keys - %i[actor_kind actor_id effective_at command_id]
      raise ArgumentError, "unknown keywords #{unknown.inspect}" unless unknown.empty?

      fields = as.slice(:actor_kind, :command_id)
      fields[:actor_id] = as[:actor_id] if as.key?(:actor_kind) || as.key?(:actor_id)
      fields[:effective_at] = as[:effective_at] if as[:effective_at]
      fields
    end

    def task_of(check)
      check.task_id && Task.find(check.task_id)
    end

    def last_event(check, type)
      Event.where(workspace_id: check.workspace_id, type: type, subject_kind: "rule_check", subject_id: check.id)
        .order(:seq).last
    end

    private_class_method :row_for, :emit_queued, :job_input, :attempt, :end_attempt, :next_attempt_number, :latest_attempt, :emit_finished,
      :wait_cause, :payload, :claimant, :emit, :task_of, :last_event
  end
end
