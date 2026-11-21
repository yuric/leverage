module Leverage
  module Rules
    # Step 6 of How a transition is gated (PRD L367, L378-L382, L392;
    # milestone 4 plan §2.1 rules 7, 9 and 10): a pending transition gated
    # again when something it waits on changes, and the same for an outward
    # action. It reads the rows of the frozen versions for the inputs as
    # they are now, and decides; it never writes.
    #
    # The inputs are the hook's, read from the task's rows and the stored
    # request (RE-2) through HookInputs, so the hash is the one the request
    # froze unless something changed. For a pending transition, in order:
    #
    #   1. A check of the transition whose hash is not the current one, or a
    #      frozen gate that has no row for the current hash, means the
    #      inputs changed: :cancel, withdrawing the transition's checks that
    #      have no result or ended in error (L367: "as a lost lease does").
    #   2. A frozen rule switched off or removed since no longer blocks: its
    #      check is withdrawn by the command that turned it off (L379). A
    #      rule saved since keeps its frozen version's result.
    #   3. A blocking check that ended in error keeps it :keep_pending under
    #      a check_error hold, planned once (rule 10), as soon as the error
    #      is recorded, though another blocking check still runs (the Holds
    #      table, L163: the hold opens when a blocking check ends in error,
    #      so the lease pauses then); at task.before_claim the provisional
    #      claim lapses instead (:cancel), the checks still running are
    #      withdrawn, and the hold still opens, naming the errored check,
    #      which is not withdrawn (L392).
    #   4. A blocking check with no result keeps it :keep_pending.
    #   5. Any other open hold keeps it :keep_pending until the last hold
    #      lifts (L378). The check_error and rerun_limit holds of the
    #      transition's own checks are not such holds: they close with the
    #      check's result, override or withdrawal, in the same command.
    #   6. A failed blocking check, not overridden, :refuse, with a failure
    #      per failed rule in the frozen order (rule 7); at
    #      task.before_claim the third distinct failing seat also opens
    #      claim_gate_failed (SM-19).
    #   7. Otherwise every gate passed, did not apply, was withdrawn or was
    #      overridden: :complete. A warn rule never blocks (RC-16).
    module Reentry
      ACTION_HOOK = "action.requested".freeze
      CLAIM_HOOK = "task.before_claim".freeze
      OWN_HOLDS = %w[check_error rerun_limit].freeze

      module_function

      # Returns a Gating::Decision. Raises ActiveRecord::RecordNotFound for
      # an id that names no pending transition, and ArgumentError for one
      # that is no longer pending.
      def call(pending_transition_id:, trigger:)
        pending = PendingTransition.find(pending_transition_id)
        raise ArgumentError, "pending transition #{pending.id} is #{pending.state}" unless pending.state == "pending"

        task = Task.find_by!(workspace_id: pending.workspace_id, id: pending.task_id)
        hook = hook_of(pending.command)
        subject = subject_of(hook, pending, task)
        inputs = HookInputs.for(hook: hook, task: task, params: pending.params || {}, seat: (subject if subject.is_a?(Seat)),
          review: (subject if subject.is_a?(Review)))
        input_hash = Gating.input_hash(hook: hook, inputs: inputs)
        linked = RuleCheck.where(workspace_id: pending.workspace_id, pending_transition_id: pending.id).to_a
        live = Catalog.versions(pending.frozen_rule_version_ids)
          .select { |entry| entry.rule.enabled && entry.rule.removed_at.nil? }
        rows = live.map do |entry|
          [ entry, StoredResults.find(task_id: task.id, rule_version_id: entry.version.id, hook: hook, round: task.round,
            subject_kind: subject && EventLog.kind_of(subject), subject_id: subject&.id, input_hash: input_hash) ]
        end

        changed = linked.any? { |check| check.result != "withdrawn" && check.input_hash != input_hash } ||
          rows.any? { |entry, row| row.nil? && entry.version.kind == "gate" }
        if changed
          withdraw = linked.select { |check| check.overridden_at.nil? && [ nil, "error" ].include?(check.result) }
          return decision(:cancel, checks_to_withdraw: withdraw.map(&:id))
        end

        own = (linked.map(&:id) + rows.filter_map { |_, row| row&.id }).uniq
        decide(task, hook, subject, rows.select { |entry, row| row && EvaluationBuilder.blocking?(entry.version) }, own)
      end

      # Gates an outward action again (L138, L384): its gate checks for its
      # current inputs. While one runs or has ended in error it waits (the
      # error under check_error); a failed one stops the action; when every
      # gate has cleared, the approval policy is planned (Decision#checks
      # and #jobs).
      #
      # Returns a Gating::Decision. Raises ActiveRecord::RecordNotFound for
      # an id that names no action.
      def action(action_id:, trigger:)
        made = Action.find(action_id)
        task = Task.find_by!(workspace_id: made.workspace_id, id: made.task_id)
        request = action_request(made, task)
        input_hash = Gating.input_hash(hook: ACTION_HOOK, inputs: request.inputs)
        rows = RuleCheck.where(workspace_id: made.workspace_id, task_id: task.id, hook: ACTION_HOOK, subject_kind: "action",
          subject_id: made.id, round: request.round, input_hash: input_hash).to_a
        versions = RuleVersion.where(id: rows.map(&:rule_version_id)).index_by(&:id)
        rules = Rule.where(id: rows.map(&:rule_id)).index_by(&:id)
        gates = rows.filter_map do |row|
          version = versions.fetch(row.rule_version_id)
          rule = rules.fetch(row.rule_id)
          next unless EvaluationBuilder.blocking?(version) && rule.enabled && rule.removed_at.nil?

          [ Catalog::Entry.new(rule: rule, version: version), row ]
        end

        waiting = decide(task, ACTION_HOOK, made, gates, rows.map(&:id), hold_open: false)
        return waiting unless waiting.action == :complete

        requested = Event.where(workspace_id: task.workspace_id, task_id: task.id, subject_kind: "action",
          subject_id: made.id, type: ACTION_HOOK).order(:seq).last
        return waiting unless requested

        checks, jobs, = EvaluationBuilder.policies(request.with(project_id: requested.project_id),
          entries: Catalog.action_policies(requested))
        decision(:complete, checks: checks, jobs: jobs)
      end

      # Steps 3 to 7 over [entry, row] pairs of the blocking gates.
      def decide(task, hook, subject, gates, own_check_ids, hold_open: true)
        gates = gates.reject { |_, row| row.overridden_at }
        running = gates.select { |_, row| row.result.nil? }
        errored = gates.select { |_, row| row.result == "error" }
        unless errored.empty?
          holds = errored.reject { |_, row| open_hold?(task, "check_error", row.id) }
            .map { |entry, row| Gating::PlannedHold.new(reason: "check_error", rule_id: entry.rule.id, rule_check_id: row.id) }
          if hook == CLAIM_HOOK
            return decision(:cancel, holds_to_open: holds, checks_to_withdraw: running.map { |_, row| row.id })
          end

          return decision(:keep_pending, holds_to_open: holds)
        end
        return decision(:keep_pending) unless running.empty?
        return decision(:keep_pending) if hold_open && held?(task, own_check_ids)

        failed = gates.select { |_, row| row.result == "failed" }
        return decision(:complete) if failed.empty?

        failures = failed.map do |entry, row|
          Gating::Failure.new(rule_id: entry.rule.id, rule_check_ref: row.id, reason: row.reason,
            route: EvaluationBuilder.route(entry.version))
        end
        decision(:refuse, failures: failures, holds_to_open: claim_gate_holds(task, hook, subject, failed))
      end

      # The hook of a gated command's state-table rows.
      def hook_of(command)
        Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
          .select { |row| row.fetch("command") == command }.filter_map { |row| row["hook"] }.first ||
          raise(ArgumentError, "#{command} has no hook")
      end

      # What the hook is about (hooks.json subject_kind): the requester at
      # task.before_claim, the review the requester holds at
      # task.before_done, nothing at the other gate hooks.
      def subject_of(hook, pending, task)
        case Contract.hooks.fetch("hooks").find { |entry| entry["hook"] == hook }.fetch("subject_kind")
        when "seat" then Seat.find_by!(workspace_id: pending.workspace_id, id: pending.requester_id)
        when "review"
          reviews = Review.where(workspace_id: pending.workspace_id, task_id: task.id, round: task.round).order(:created_at, :id)
          reviews.find_by(reviewer_seat_id: pending.requester_id) || reviews.last
        end
      end

      # Whether a hold other than the transition's own check_error and
      # rerun_limit holds is open on the task.
      def held?(task, own_check_ids)
        Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil)
          .where.not(reason: OWN_HOLDS, rule_check_id: own_check_ids).exists? ||
          Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil, reason: OWN_HOLDS, rule_check_id: nil)
            .exists?
      end

      def open_hold?(task, reason, check_id)
        Hold.where(workspace_id: task.workspace_id, task_id: task.id, reason: reason, rule_check_id: check_id,
          closed_at: nil).exists?
      end

      def claim_gate_holds(task, hook, subject, failed)
        return [] unless hook == CLAIM_HOOK

        failed.filter_map do |entry, row|
          next unless ClaimGate.reached?(task, entry.rule.id, subject.id)

          Gating::PlannedHold.new(reason: "claim_gate_failed", rule_id: entry.rule.id, rule_check_id: row.id)
        end
      end

      def action_request(made, task)
        Gating::Request.new(workspace_id: task.workspace_id, task_id: task.id, project_id: task.project_id,
          hook: ACTION_HOOK, round: task.round, subject_kind: "action", subject_id: made.id, requester_kind: "app",
          requester_id: nil, command_key: nil,
          inputs: HookInputs.for(hook: ACTION_HOOK, task: task, params: { "aid" => made.id }))
      end

      def decision(action, failures: [], holds_to_open: [], checks_to_withdraw: [], checks: [], jobs: [])
        Gating::Decision.new(action: action, failures: failures, effects: [], holds_to_open: holds_to_open,
          holds_to_close: [], checks_to_withdraw: checks_to_withdraw, checks: checks, jobs: jobs)
      end

      private_class_method :decide, :hook_of, :subject_of, :held?, :open_hold?, :claim_gate_holds, :action_request,
        :decision
    end
  end
end
