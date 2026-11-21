module Leverage
  module Transitions
    module Entries
      # enable_rule (PRD L379; milestone 4 plan RD-3, RD-5): the owner turns
      # a rule on (rule.enabled). A request already made is not touched. A
      # rule that is on already, or removed, is invalid_state: nothing would
      # change (milestone 4 WP8's choice, in its notes).
      #
      # Turning off a blocking task.before_claim gate closed its
      # claim_gate_failed holds (L166); turning it on brings the stored
      # failures back, and claim-next skips the task again for each seat
      # that failed it (Rules::ClaimFilter). So a Ready task that
      # ClaimGate::SEATS seats have failed on its current contract is held
      # with claim_gate_failed again, with its Needs you item, naming the
      # latest failed check (L393; milestone 4 review, finding 5): otherwise
      # every seat would skip it with nothing for the owner.
      #
      # Params: id (the rule).
      class EnableRule < Entry
        def load(ctx)
          @rule = Rule.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such rule")
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if @rule.removed_at || @rule.enabled
          causes.compact
        end

        def perform(ctx)
          RuleRecords.enable(ctx, @rule)
          hold_failed_claims(ctx)
          @result = nil
        end

        private

        def hold_failed_claims(ctx)
          version = RuleRecords.current_version(@rule)
          return unless version.hook == Rules::ClaimGate::HOOK && Rules::EvaluationBuilder.blocking?(version)

          Task.where(workspace_id: @rule.workspace_id, state: "ready").order(:created_at, :id).each do |task|
            next unless Rules::Scope.covers?(version, task)
            next if Rules::ClaimGate.failed_seat_ids(task, @rule.id).size < Rules::ClaimGate::SEATS
            next if ::Hold.exists?(workspace_id: task.workspace_id, task_id: task.id, reason: "claim_gate_failed",
              rule_id: @rule.id, closed_at: nil)

            check = latest_failure(task)
            planned = Gating::PlannedHold.new(reason: "claim_gate_failed", rule_id: @rule.id, rule_check_id: check.id)
            Gate.open_hold(ctx, task, planned, check_id: check.id, cause_id: nil)
          end
        end

        # The latest failed, not overridden check of the rule that counts
        # for the task's current contract and round.
        def latest_failure(task)
          seats = Rules::ClaimGate.failed_seat_ids(task, @rule.id)
          RuleCheck.where(workspace_id: task.workspace_id, task_id: task.id, rule_id: @rule.id, hook: Rules::ClaimGate::HOOK,
            round: task.round, subject_kind: "seat", subject_id: seats, result: "failed", overridden_at: nil)
            .order(:updated_at, :created_at, :id).last
        end
      end
    end
  end
end
