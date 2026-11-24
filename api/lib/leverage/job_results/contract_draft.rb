module Leverage
  module JobResults
    # A planner's result runs Complete contract with the planner's identity
    # and the job result call's key (RE-6, RD-37).
    module ContractDraft
      module_function

      def check_shape(_job, answer)
        unless answer.key?("details") && answer["criteria"].is_a?(Array)
          raise Transitions::Invalid, "A contract draft's result is a contract."
        end
      end

      def refusals(task)
        task&.state == "backlog" ? [] : [ Transitions::Refusal.new(code: "invalid_state") ]
      end

      def perform(ctx, job, task, seat:, answer:, tokens:, spend:)
        Costs.report(ctx, task: task, subject: job, tokens: tokens, spend: spend)
        contract = answer.slice("title", "details", "criteria", "actions")
        # The planner's default empty list leaves the owner's actions in place.
        if Array(contract["actions"]).empty?
          contract["actions"] = Actions.for_task(task).map { |action| action.attributes.slice("kind", "description") }
        end
        stored = { "work_reference" => task.work_reference, "minimum_strength_rank" => task.minimum_strength_rank,
                   "budget_cap" => task.budget_cap&.to_f }
        Transitions.run_as(ctx, "complete_contract", requester: seat, key: ctx.request.key,
          params: contract.merge(stored).merge("id" => task.id))
      end
    end
  end
end
