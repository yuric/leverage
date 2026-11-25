module Leverage
  # A pending transition's life (PRD L374 to L384; milestone 4 plan §2.1,
  # RE-2 to RE-6, rules 9 and 11): a command that waits on a blocking model
  # check is stored whole with its request, and later completes, is refused
  # or is cancelled inside whatever command or timer brings its last result,
  # as its requester (Transitions::Context#as_requester). The only writer
  # of pending_transitions and of a pending commands row's later outcome:
  # the requester's commands row reads completed (with the entry's result)
  # or refused (with the refusal), and is marked notify, which GET /v1/next
  # reads as kind command until GET /v1/commands/{key} is read (RE-3,
  # DB-34). cancel is the one place a waiting command is ended from outside
  # (rule 11).
  #
  # The events of a completion, and of a failed gate's effect at re-entry,
  # carry the requester as actor, the requester's key and, as cause_id, the
  # check.finished that settled it, or the check.overridden when the check
  # never finished (RD-45's row held at the re-run limit; traces 07, 16 to
  # 18). What the app writes beside them (a withdrawal, a hold the decision
  # opens) carries the command's own actor and key, or the ones the caller
  # names (a timer: actor app, no key, its due time), with the
  # check.finished of that hold's check as cause when this command wrote
  # one (traces 07 and 18).
  module PendingTransitions
    PENDING = "pending".freeze
    # RC-17: the codes a waiting command ended from outside reads.
    ENDING_CODES = %w[task_cancelled lease_expired invalid_state].freeze
    # Refusals that do not end a waiting command at re-entry: a hold leaves
    # it running (L378, RE-4), and the task answers pending to its holder.
    KEEP_RUNNING = %w[on_hold pending].freeze
    # Refusals a waiting command is not met with again at re-entry: it was
    # sent on the briefing it had, and its holder cannot acknowledge again
    # while it waits (acknowledge_briefing is not allowed while pending).
    # A rule turned off, removed or saved changes the briefing, and the
    # transition still completes if nothing else blocks it (L379).
    IGNORED_AT_REENTRY = %w[briefing_not_acknowledged briefing_changed].freeze
    # The hooks whose command a pending transition stores (rules 6, 7).
    GATE_HOOKS = %w[task.before_ready task.before_claim task.before_submit task.before_done].freeze

    # A stored request as Context#as_requester reads it: what run_as
    # performs as someone else, with no pending_transitions row.
    Requested = Data.define(:command, :workspace_id, :requester_kind, :requester_id, :command_key, :params)

    module_function

    # Stores entry's command as pending (Gate, when evaluation is :pending):
    # the frozen rule versions, the requester and its key, and params, the
    # request it will complete with (RE-2). task: is the task it waits on
    # (default: the one params id names). Returns the PendingTransition.
    def store(ctx, entry, evaluation, params, task: nil)
      task ||= Task.find_by!(workspace_id: ctx.workspace.id, id: params.fetch("id"))
      kind, = ctx.actor
      PendingTransition.create!(workspace_id: ctx.workspace.id, task_id: task.id, command: entry.command,
        command_key: ctx.request.key, requester_kind: kind, requester_id: ctx.request.caller_id || ctx.caller_id,
        frozen_rule_version_ids: evaluation.frozen_rule_version_ids, state: PENDING, params: params.to_h)
    end

    # Gates the transition again on trigger, a Gating::Trigger (step 6,
    # rule 9): first the entry's own refusals as the requester, one that
    # now applies cancelling it (RC-17's code, else invalid_state); then
    # Gating.reenter, and the decision: :complete performs it, :refuse
    # takes the hook's failed-gate effect, :cancel ends it with
    # invalid_state, :keep_pending opens the holds it plans. **as names
    # the actor, key and effective time of what the app writes beside it
    # (a timer's). Returns the Gating::Decision, or nil when the
    # transition is no longer pending or a refusal cancelled it.
    def reenter(ctx, pending, trigger, **as)
      pending.reload
      return nil unless pending.state == PENDING

      code = refused_now(ctx, pending)
      if code
        cancel(ctx, pending, ENDING_CODES.include?(code) ? code : "invalid_state", **as)
        return nil
      end

      close_settled_holds(ctx, pending, trigger, **as)
      decision = Gating.reenter(pending_transition_id: pending.id, trigger: trigger)
      cause = cause_of(pending, trigger)
      case decision.action
      when :complete then complete(ctx, pending, cause_id: cause&.id)
      when :refuse then refuse(ctx, pending, decision, cause_id: cause&.id, **as)
      when :cancel
        cancel(ctx, pending, "invalid_state", withdraw: decision.checks_to_withdraw, **as)
        open_holds(ctx, pending, decision.holds_to_open, **as)
      when :keep_pending then open_holds(ctx, pending, decision.holds_to_open, **as)
      end
      open_missing_error_item(ctx, pending, trigger, **as) if %i[keep_pending cancel].include?(decision.action)
      decision
    end

    # Performs the stored command as its requester, with cause_id the
    # check.finished or check.overridden that settled it (L241): its
    # load and perform, then ReviewerEligibility.after_command, and the
    # requester's commands row reads completed with the result.
    def complete(ctx, pending, cause_id:)
      entry = nil
      ctx.as_requester(pending, cause_id: cause_id) do
        entry = loaded_entry(ctx, pending)
        Transitions.perform(ctx, entry)
      end
      settle(pending, Transitions::Outcome.completed(entry.result))
    end

    # Refuses the stored command with decision's first failure (rule 7):
    # the hook's failed-gate effect as the requester (Gate.fail), then the
    # holds the decision opens (claim_gate_failed). The requester's
    # commands row reads what the effect reads: refused blocked_by_rule, or
    # completed for Complete contract (RD-10) and a pass that became a
    # failed review (SM-6).
    def refuse(ctx, pending, decision, cause_id:, **as)
      failure = decision.failures.first || raise(ArgumentError, "a refusal names a failure")
      outcome = nil
      ctx.as_requester(pending, cause_id: cause_id) do
        entry = loaded_entry(ctx, pending)
        outcome = Transitions::Gate.fail(ctx, entry, failure, cause_id: cause_id)
      end
      lapse_claim(pending)
      settle(pending, outcome, state: "refused")
      open_holds(ctx, pending, decision.holds_to_open, **as)
      outcome
    end

    # Ends the waiting command from outside (rule 11): code is one of
    # RC-17's three (task_cancelled, lease_expired, invalid_state). Every
    # check of the transition that has not settled it (no result, or an
    # error not overridden) is withdrawn with its open job, the check_error
    # and rerun_limit holds those checks opened are closed with their
    # items, a provisional claim's reservation lapses, the stored request
    # is emptied, and the requester's command reads refused with the code,
    # marked notify. withdraw: limits the checks to those it names, when
    # re-entry decided which (an errored claim check is kept: L392). The
    # caller calls it before the event that takes the task or the review
    # away (trace 18). Returns nil.
    def cancel(ctx, pending, code, withdraw: nil, **as)
      raise ArgumentError, "#{code.inspect} is not one of #{ENDING_CODES.inspect}" unless ENDING_CODES.include?(code.to_s)

      pending.reload
      return nil unless pending.state == PENDING

      checks = RuleChecks.unsettled(pending)
      checks = checks.select { |check| withdraw.include?(check.id) } if withdraw
      task = Task.find(pending.task_id)
      checks.each do |check|
        job = RuleChecks.open_job(check)
        RuleChecks.withdraw(ctx, check, **as)
        Jobs.withdraw(ctx, job, **as) if job
      end
      close_own_holds(ctx, task, checks, **as)
      lapse_claim(pending)
      settle(pending, Transitions::Outcome.refused(Transitions::Refusal.new(code: code.to_s)), state: "cancelled")
      nil
    end

    # The task's pending transition (state pending), or nil.
    def of(task)
      PendingTransition.find_by(workspace_id: task.workspace_id, task_id: task.id, state: PENDING)
    end

    # The pending transition a request's key names (its requester and
    # key), or nil: how a command learns that it now waits, and how a claim
    # finds the task its key reserved.
    def for_request(request)
      return nil if request.by_app? || request.caller_id.nil?

      PendingTransition.find_by(requester_kind: request.caller_kind, requester_id: request.caller_id,
        command_key: request.key, state: PENDING)
    end

    # Links the commands row of a command that answered pending to its
    # transition (commands.pending_transition_id).
    def link(command_row, pending)
      command_row.update!(pending_transition_id: pending.id)
    end

    # Whether a gated command meets a task that already waits on another
    # command's pending transition: a task has at most one (PRD L373), so
    # the owner's or a planner's second Complete contract answers pending
    # too (RC-41 leaves them unblocked otherwise). The entry is loaded and
    # its state row found.
    def taken?(ctx, entry)
      return false unless GATE_HOOKS.include?(entry.hook)

      task_id = entry.gate_request_fields(ctx)[:task_id]
      pending = task_id && PendingTransition.find_by(workspace_id: ctx.workspace.id, task_id: task_id, state: PENDING)
      !pending.nil? && pending.command_key != ctx.request.key
    end

    # Whether the task the command is about has a pending transition that
    # the calling seat waits on, as its holder, the reviewer holding its
    # review, or its provisional claimant, and the command is not one the
    # registry allows while pending: the command then answers pending
    # (RE-4, L375, SM-14). The owner's commands and a planner's are never
    # blocked (RC-41). One check, from the registry, for every command.
    def blocks?(ctx, command)
      request = ctx.request
      return false unless request.caller_kind == "seat" && !allowed_while_pending?(command)

      waiting = waiting_tasks(ctx.workspace.id, request.caller_id)
      return false if waiting.empty?

      named = named_task_ids(ctx.workspace.id, request.params)
      named.empty? || named.intersect?(waiting)
    end

    def allowed_while_pending?(command)
      entry = Contract.state_machine.fetch("commands").find { |row| row.fetch("command") == command.to_s }
      entry.nil? || entry.fetch("allowed_while_pending")
    end

    # --- private -------------------------------------------------------------

    # The code of a refusal the stored command meets now, as its requester,
    # or nil (rule 9). A hold, the pending answer itself and the briefing
    # (IGNORED_AT_REENTRY) do not count.
    def refused_now(ctx, pending)
      codes = nil
      ctx.as_requester(pending, cause_id: nil) do
        entry = Transitions::Table.entry_for(pending.command).new(pending.command)
        entry.load(ctx)
        codes = entry.refusals(ctx).map { |refusal| refusal.is_a?(Transitions::Refusal) ? refusal.code : refusal.to_s }
      end
      Transitions::Precedence.first(codes - KEEP_RUNNING - IGNORED_AT_REENTRY)&.code
    rescue Transitions::NotFound, Transitions::Invalid
      "invalid_state"
    end

    # The stored command's entry, loaded as the requester, with its state
    # row found (refusals finds it; hook reads it).
    def loaded_entry(ctx, pending)
      entry = Transitions::Table.entry_for(pending.command).new(pending.command)
      entry.load(ctx)
      entry.refusals(ctx)
      entry
    end

    # The event that settled the transition: the trigger's check's latest
    # check.finished, else its check.overridden; when the last hold lifts,
    # the latest of the transition's checks (L241, L242).
    def cause_of(pending, trigger)
      checks = if trigger.rule_check_id
        RuleCheck.where(id: trigger.rule_check_id).to_a
      else
        RuleCheck.where(workspace_id: pending.workspace_id, pending_transition_id: pending.id).to_a
      end
      finished = checks.filter_map { |check| RuleChecks.last_finished(check) }.max_by(&:seq)
      finished || checks.filter_map { |check| RuleChecks.last_overridden(check) }.max_by(&:seq)
    end

    # The requester's commands row reads the outcome, marked notify; the
    # transition leaves pending and its request is emptied (RE-2).
    def settle(pending, outcome, state: "completed")
      pending.update!(state: state, params: nil)
      row = Command.find_by(caller_kind: pending.requester_kind, caller_id: pending.requester_id, key: pending.command_key)
      result = if row&.command == "add_task" && outcome.completed?
        { "task_id" => pending.task_id, "state" => Task.find(pending.task_id).state }
      else
        outcome.result
      end
      row&.update!(outcome: outcome.outcome.to_s, result: result, refusal: Idempotency.stored_refusal(outcome.refusal),
        notify: true, read_at: nil)
    end

    # A provisional claim's reservation lapses (RE-5): the claimant no
    # longer holds the Ready task. No event: none recorded it (L390).
    def lapse_claim(pending)
      return unless pending.command == "claim"

      task = Task.find(pending.task_id)
      task.update!(holder_seat_id: nil) if task.state == "ready" && task.holder_seat_id == pending.requester_id
    end

    # Opens the holds a decision plans, each naming its check, by the app
    # unless the caller names an actor, with the check's check.finished of
    # this command as cause (traces 07 and 18). A hold of that reason
    # already open for that check is not opened again.
    def open_holds(ctx, pending, planned, **as)
      return if planned.empty?

      task = Task.find(pending.task_id)
      planned.each do |hold|
        next if Hold.exists?(workspace_id: task.workspace_id, task_id: task.id, reason: hold.reason,
          rule_check_id: hold.rule_check_id, closed_at: nil)

        Transitions::Gate.open_hold(ctx, task, hold, check_id: hold.rule_check_id, **as)
      end
    end

    # A check that has just ended in error (the trigger's check) while the
    # orchestrator is online gets its "A check could not run" item (L400)
    # when its check_error hold is already open with none: the hold was
    # opened while the orchestrator was offline, which opens no item
    # (SM-39), and the orchestrator's return queued the check again. The
    # item opens by the app, with the check's check.finished of this
    # command as cause, as Gate.open_hold opens it; with it open, the
    # orchestrator_offline timer leaves the check with the owner.
    def open_missing_error_item(ctx, pending, trigger, **as)
      return unless trigger.kind == :check_timed_out && trigger.rule_check_id
      return unless RolePresence.online?(ctx.workspace, "orchestrator", ctx.at)

      check = RuleCheck.find_by(id: trigger.rule_check_id, pending_transition_id: pending.id, result: "error", overridden_at: nil)
      hold = check && Hold.find_by(workspace_id: pending.workspace_id, task_id: pending.task_id, reason: "check_error",
        rule_check_id: check.id, closed_at: nil)
      return unless hold

      cause = ctx.events.reverse.find { |event| event.type == "check.finished" && event.subject_id == check.id }
      fields = { actor_kind: "app", actor_id: nil }.merge(RuleChecks.event_fields(as))
      Holds.open_item(ctx, hold, task: Task.find(pending.task_id), facts: { rule_id: check.rule_id, rule_check_id: check.id },
        cause_id: cause&.id, **fields)
    end

    # The choice a check's own hold's item is resolved with when the check
    # settles at re-entry (needs_you.json; WP0T's choice 9).
    SETTLED_CHOICES = { check_finished: "run_again", check_overridden: "override_once",
                        check_withdrawn: "turn_rule_off", rule_switched_off: "turn_rule_off" }.freeze

    # The check_error and rerun_limit holds of the transition's checks that
    # have settled since (a re-run's result, an override, a withdrawal)
    # close before it is gated again, by the app with the command's key and
    # that check's check.finished of this command as cause (rule 9: no hold
    # open; trace 19 command 21). A closer that closed the hold itself
    # (override_check, a rule turned off) leaves nothing here.
    def close_settled_holds(ctx, pending, trigger, **as)
      checks = RuleCheck.where(workspace_id: pending.workspace_id, pending_transition_id: pending.id).to_a
        .select { |check| check.overridden_at || ![ nil, "error" ].include?(check.result) }
      return if checks.empty?

      fields = { actor_kind: "app", actor_id: nil }.merge(RuleChecks.event_fields(as))
      task = Task.find(pending.task_id)
      Hold.where(workspace_id: pending.workspace_id, task_id: task.id, closed_at: nil, reason: Holds::CHECK_HOLDS,
        rule_check_id: checks.map(&:id)).order(:opened_at, :id).each do |hold|
        cause = ctx.events.reverse.find { |event| event.type == "check.finished" && event.subject_id == hold.rule_check_id }
        Holds.close(ctx, hold: hold, task: Task.find(task.id), choice: SETTLED_CHOICES[trigger.kind], cause_id: cause&.id,
          **fields)
      end
    end

    # Closes the open check_error and rerun_limit holds of these checks,
    # each with its item (rule 11).
    def close_own_holds(ctx, task, checks, **as)
      return if checks.empty?

      fields = RuleChecks.event_fields(as)
      Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil, reason: %w[check_error rerun_limit],
        rule_check_id: checks.map(&:id)).order(:opened_at, :id).each do |hold|
        Holds.close(ctx, hold: hold, task: Task.find(task.id), **fields)
      end
    end

    # The tasks whose pending transition the seat waits on: those it holds
    # (a builder's submit, a provisional claim) and those whose open review
    # it holds (a reviewer's pass).
    def waiting_tasks(workspace_id, seat_id)
      held = Task.where(workspace_id: workspace_id, holder_seat_id: seat_id).select(:id)
      reviewed = Review.where(workspace_id: workspace_id, reviewer_seat_id: seat_id, verdict: nil).select(:task_id)
      PendingTransition.where(workspace_id: workspace_id, state: PENDING)
        .where(task_id: held).or(PendingTransition.where(workspace_id: workspace_id, state: PENDING, task_id: reviewed))
        .pluck(:task_id)
    end

    # The tasks a request names: id or task_id (a task or a review),
    # review_id.
    def named_task_ids(workspace_id, params)
      ids = params.values_at("id", "task_id", "review_id").compact.select { |id| id.is_a?(String) }
      return [] if ids.empty?

      Task.where(workspace_id: workspace_id, id: ids).pluck(:id) +
        Review.where(workspace_id: workspace_id, id: ids).pluck(:task_id)
    end

    private_class_method :refused_now, :loaded_entry, :close_settled_holds, :cause_of, :settle, :lapse_claim, :open_holds,
      :open_missing_error_item, :close_own_holds,
      :waiting_tasks, :named_task_ids
  end
end
