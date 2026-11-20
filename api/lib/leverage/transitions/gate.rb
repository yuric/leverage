module Leverage
  module Transitions
    # Runs a state-table row's hook for an entry (PRD, How a transition is
    # gated; milestone 4 plan §2.1, rules 1 to 8, ADR 0011): gating reads
    # and plans, the gate writes what was planned, and a command that must
    # wait is stored whole and performed later by the same entry. The only
    # caller of Gating.evaluate.
    #
    # call asks, at the hook, with the hashed inputs of HookInputs and the
    # entry's task, round and subject, and writes the plan: a pending
    # transition when the evaluation waits (PendingTransitions.store), the
    # rule check rows with their attempts, events and jobs (RuleChecks.write)
    # and the holds the plan opens. It answers a Result; outcome then turns
    # it into the command's Outcome: perform (no blocking failure, nothing
    # to wait on), pending (202), or the hook's failed-gate effect (fail,
    # hooks.json failed_gate):
    #
    #   hold_contract_incomplete  the entry performs its contract change
    #                             only, then contract_incomplete opens with
    #                             the rule; the command reads completed
    #                             (RD-10)
    #   refuse                    nothing of the entry is performed; refused
    #                             blocked_by_rule with the rule and the
    #                             reason of the first failure (rule 7)
    #   failed_review             fail_review's rows, with the check as the
    #                             failed criterion (SM-6); reads completed
    #
    # A blocking failure takes effect at once: the model checks planned
    # beside it are not written, since no transition is left for them to
    # gate. A warn failure is recorded on its row and lets the command
    # through (L337). A refused command still commits the rows it made and
    # their check.finished (RE-7): the pipeline commits a refusal.
    module Gate
      # An Evaluation this gate cannot apply: one that waits with no task to
      # wait on, or that defers policies (action.requested, milestone 5).
      class Unsupported < StandardError; end

      FAILED_GATE = "blocked_by_rule".freeze
      # The holds a rule check opens with an item that names the rule and
      # the check (needs_you.json facts).
      CHECK_ITEMS = %w[check_error claim_gate_failed rerun_limit].freeze

      # What call wrote: the evaluation, the rows in evaluation.checks
      # order (nil for a check not written), and the pending transition.
      Result = Data.define(:evaluation, :checks, :pending) do
        def pending? = !pending.nil?

        # The first blocking failure, in Catalog's order, or nil.
        def failure = evaluation.failures.first
      end

      module_function

      # Returns the Result, or nil when the row has no hook.
      def call(ctx, entry)
        hook = entry.hook
        return nil unless hook

        entry.before_gate(ctx) if entry.respond_to?(:before_gate)
        request = request_for(ctx, entry, hook)
        evaluation = Gating.evaluate(request)
        unless evaluation.deferred_rule_ids.empty?
          raise Unsupported, "#{hook}: deferred policies need outward actions (milestone 5)"
        end

        task = request.task_id && Task.find_by!(workspace_id: ctx.workspace.id, id: request.task_id)
        write(ctx, entry, evaluation, task)
      end

      # The command's Outcome for a Result: performs the entry (and
      # ReviewerEligibility.after_command), answers pending, or takes the
      # failed-gate effect. A nil Result (no hook) performs.
      def outcome(ctx, entry, result)
        return Outcome.new(outcome: :pending) if result&.pending?
        return fail(ctx, entry, result.failure, checks: result.checks) if result&.failure

        Transitions.perform(ctx, entry)
        Outcome.completed(entry.result, once: entry.once)
      end

      # Takes the hook's failed-gate effect for failure (rule 7), at once or
      # at re-entry (PendingTransitions.refuse, inside as_requester). The
      # failure's rule_check_ref is an index into checks, or a rule_checks
      # id. cause_id is what the effect's hold or failed review carries; at
      # once it is the check's check.finished. Returns the Outcome.
      def fail(ctx, entry, failure, checks: [], cause_id: nil)
        check = check_of(failure, checks)
        cause_id ||= check && RuleChecks.last_finished(check)&.id
        case effect(entry.hook)
        when "hold_contract_incomplete"
          entry.perform_contract_change(ctx)
          task = Task.find(check&.task_id || ctx.request.params.fetch("id"))
          open_hold(ctx, task, Gating::PlannedHold.new(reason: "contract_incomplete", rule_id: failure.rule_id,
            rule_check_id: check&.id), check_id: check&.id, cause_id: cause_id, actor_kind: ctx.actor.first,
            actor_id: ctx.actor.last)
          ReviewerEligibility.after_command(ctx, entry)
          Outcome.completed(entry.result)
        when "failed_review"
          entry.fail_for_gate(ctx, check, cause_id: cause_id)
          Outcome.completed(entry.result)
        when "refuse"
          Outcome.refused(Refusal.new(code: FAILED_GATE, rule_id: failure.rule_id, reason: failure.reason || check&.reason))
        else
          raise Unsupported, "#{entry.hook}: a failed gate here needs milestone 5 (#{effect(entry.hook).inspect})"
        end
      end

      # Opens a hold a rule check causes (rules 6, 7, 10; trace 07, 17, 18):
      # by the app unless an actor is named, with the command's key (or the
      # one named), naming the rule and the check, with the check's
      # check.finished written in this command as cause unless cause_id:
      # is given. A check_error item opens only while the orchestrator is
      # online (SM-39). Returns the Hold.
      def open_hold(ctx, task, planned, check_id:, cause_id: :written, actor_kind: "app", actor_id: nil, **as)
        if cause_id == :written
          cause_id = ctx.events.reverse.find { |event| event.type == "check.finished" && event.subject_id == check_id }&.id
        end
        facts = CHECK_ITEMS.include?(planned.reason) && check_id ? { rule_id: planned.rule_id, rule_check_id: check_id } : {}
        item = planned.reason != "check_error" || RolePresence.online?(ctx.workspace, "orchestrator", ctx.at)
        hold = Holds.open(ctx, task: task, reason: planned.reason, rule_id: planned.rule_id, cause_id: cause_id,
          facts: facts, actor_kind: actor_kind, actor_id: actor_id, item: item,
          **supported(rule_check_id: check_id, **RuleChecks.event_fields(as).except(:actor_kind, :actor_id)))
        hold.update!(rule_check_id: check_id) if check_id && hold.rule_check_id != check_id
        hold
      end

      # The Gating::Request at the entry's hook: the entry's task, round and
      # subject, the requester and its key, and the hook's hashed inputs
      # (rule 1) from the task's rows and the command's request.
      def request_for(ctx, entry, hook)
        kind, id = ctx.actor
        fields = entry.gate_request_fields(ctx)
        # A hook about the seat (hooks.json subject_kind) is about the
        # calling seat when the entry names no subject.
        if fields[:subject_kind].nil? && subject_kind(hook) == "seat" && ctx.request.caller_kind == "seat"
          fields = fields.merge(subject_kind: "seat", subject_id: ctx.request.caller_id)
        end
        if fields[:task_id] && fields[:inputs].blank?
          task = Task.find_by!(workspace_id: ctx.workspace.id, id: fields[:task_id])
          seat = Seat.find(fields[:subject_id]) if fields[:subject_kind] == "seat"
          seat ||= Seat.find(ctx.request.caller_id) if subject_kind(hook) == "seat" && ctx.request.caller_kind == "seat"
          fields = fields.merge(inputs: HookInputs.for(hook: hook, task: task, params: ctx.request.params, seat: seat,
            review: (Review.find(fields[:subject_id]) if fields[:subject_kind] == "review")))
        end
        Gating::Request.new(workspace_id: ctx.workspace.id, hook: hook, requester_kind: kind,
          requester_id: ctx.request.caller_id || id, command_key: ctx.request.key, **fields)
      end

      # --- private -------------------------------------------------------------

      # Writes the plan. A blocking failure takes effect at once, so only
      # the rows with a result are written then; else a waiting evaluation
      # stores its transition first, so its check.queued names it.
      def write(ctx, entry, evaluation, task)
        if evaluation.failures.any?
          kept = evaluation.checks.map { |check| check.result.nil? ? nil : check }
          rows = RuleChecks.write(ctx, with_checks(evaluation, kept.compact), task: task)
          checks = kept.map { |check| check && rows.shift }
          open_planned(ctx, task, evaluation.holds_to_open, checks)
          return Result.new(evaluation: evaluation, checks: checks, pending: nil)
        end

        pending = nil
        if evaluation.outcome == :pending
          raise Unsupported, "#{entry.hook}: a pending transition needs a task" unless task

          pending = PendingTransitions.store(ctx, entry, evaluation, ctx.request.params.to_h, task: task)
          entry.wait(ctx, pending) if entry.respond_to?(:wait)
        end
        checks = RuleChecks.write(ctx, evaluation, task: task, pending: pending)
        open_planned(ctx, task, evaluation.holds_to_open, checks)
        Result.new(evaluation: evaluation, checks: checks, pending: pending)
      end

      # The planned holds, each naming its check (an index into checks or a
      # rule_checks id).
      def open_planned(ctx, task, holds, checks)
        holds.each do |planned|
          ref = planned.rule_check_id
          check_id = ref.is_a?(Integer) ? checks.fetch(ref)&.id : ref
          open_hold(ctx, task, planned, check_id: check_id)
        end
      end

      # An evaluation with only the given checks and no jobs or holds: what
      # is written beside a blocking failure.
      def with_checks(evaluation, checks)
        Gating::Evaluation.new(outcome: :completed, frozen_rule_version_ids: evaluation.frozen_rule_version_ids,
          checks: checks, jobs: [], failures: evaluation.failures, warnings: evaluation.warnings,
          effects: evaluation.effects, holds_to_open: [])
      end

      def check_of(failure, checks)
        ref = failure.rule_check_ref
        return checks.fetch(ref) if ref.is_a?(Integer)

        ref && RuleCheck.find(ref)
      end

      def effect(hook) = hook_entry(hook)&.fetch("failed_gate")

      def subject_kind(hook) = hook_entry(hook)&.fetch("subject_kind")

      def hook_entry(hook)
        Contract.hooks.fetch("hooks").find { |entry| entry["hook"] == hook }
      end

      # The keywords of Holds.open it takes (holds.rb is milestone 4's WP5):
      # rule_check_id, effective_at and command_id are passed once it takes
      # them; until then the hold's rule_check_id is set after it opens. A
      # nil rule_check_id or effective_at is left out; a named command_id is
      # passed even when nil (a timer's).
      def supported(**keywords)
        taken = Holds.method(:open).parameters.map(&:last)
        keywords.select { |name, value| taken.include?(name) && (!value.nil? || name == :command_id) }
      end

      private_class_method :write, :open_planned, :with_checks, :check_of, :effect, :subject_kind, :hook_entry, :supported
    end
  end
end
