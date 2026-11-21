module Leverage
  module JobResults
    # An approval is the policy's result and the orchestrator's action decision.
    module Approval
      EFFECTS = { "approve" => "approved", "stop" => "stopped", "pass_to_owner" => "passed_to_owner" }.freeze

      module_function

      def check_shape(_job, answer)
        unless EFFECTS.key?(answer["decision"]) && answer["reason"].is_a?(String) && answer["reason"].length <= 500
          raise Transitions::Invalid, "An approval result needs a decision and a reason of at most 500 characters."
        end
      end

      def refusals(task)
        task&.state == "finishing" ? [] : [ "invalid_state" ]
      end

      def perform(ctx, job, task, seat:, answer:, tokens:, spend:)
        check = ::RuleCheck.find_by!(workspace_id: task.workspace_id, task_id: task.id, id: job.target_id)
        action = Actions.for_task(task).find(check.subject_id)
        raise ArgumentError, "a settled action cannot take an approval result" unless action.state == "requested" && check.round == task.round

        decision = answer.fetch("decision")
        check.effect = EFFECTS.fetch(decision)
        finished = RuleChecks.finish(ctx, check, result: "applied", reason: answer.fetch("reason"), tokens: tokens, spend: spend)
        Costs.report(ctx, task: task, subject: job, tokens: tokens, spend: spend)
        if decision == "pass_to_owner"
          Finishing.open_owner_approval(ctx, action, check: check, cause: finished)
          return :completed
        end

        outcome = Transitions.run_as(ctx, "#{decision}_action", requester: seat, key: ctx.request.key,
          params: { "id" => action.id, "job_id" => job.id })
        raise ArgumentError, "an accepted approval result must settle its requested action" unless outcome == :completed

        outcome
      end
    end
  end
end
