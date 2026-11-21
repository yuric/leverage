module Leverage
  module Transitions
    module Entries
      # rerun_check (PRD L392, L400, L423; milestone 4 plan RD-42, RD-43):
      # Run it again, for a check that ended in error only.
      #
      #   rerun_queues          at any hook but before an agent starts it, the
      #                         check runs again as a new attempt of the same
      #                         row with a job of its own
      #                         (RuleChecks.queue_attempt: check.queued, then
      #                         job.queued, trace 19 command 20), with RC-33's
      #                         input for that attempt; its check_error hold closes
      #                         when a result other than error arrives.
      #   rerun_of_claim_check  an errored claim check has already lapsed its
      #                         provisional claim: its check_error hold
      #                         closes (run_again) and nothing is queued, so
      #                         the next claim checks afresh.
      #
      # Any other check, a check of a cancelled task, or an errored claim
      # check with no hold left to close is invalid_state.
      #
      # Params: id (the rule check).
      class RerunCheck < Entry
        CLAIM_HOOK = "task.before_claim".freeze
        ERROR = "error".freeze
        RUN_AGAIN = "run_again".freeze
        JOB_KIND = "rule_check".freeze

        def load(ctx)
          @check = RuleCheck.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such rule check")
          @task = @check.task_id && Task.find(@check.task_id)
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil, [ claim? ? "rerun_of_claim_check" : "rerun_queues" ]) ]
          causes << invalid_state unless @check.result == ERROR
          causes << invalid_state if @task.nil? || @task.state == "cancelled"
          causes << invalid_state if claim? && hold.nil?
          causes.compact
        end

        def perform(ctx)
          if claim?
            Holds.close(ctx, hold: hold, task: @task, choice: RUN_AGAIN)
          else
            version = RuleVersion.find(@check.rule_version_id)
            RuleChecks.queue_attempt(ctx, @check, kind: JOB_KIND, seat_role: version.checker_role || "orchestrator")
          end
          @result = nil
        end

        private

        def claim? = @check.hook == CLAIM_HOOK

        # The open check_error hold of this check: named by it, or, for a
        # hold that names no check, by its rule.
        def hold
          @hold ||= ::Hold.where(workspace_id: @check.workspace_id, task_id: @check.task_id, reason: "check_error",
            closed_at: nil).order(:opened_at, :id).find do |open|
              open.rule_check_id == @check.id || (open.rule_check_id.nil? && open.rule_id == @check.rule_id)
            end
        end

        def invalid_state = Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal"))
      end
    end
  end
end
