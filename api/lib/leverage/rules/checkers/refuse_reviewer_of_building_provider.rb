module Leverage
  module Rules
    module Checkers
      # "A different provider reviews every task" (PRD L441, L448;
      # milestone 4 plan §2.1 rule 8, RD-50): a policy at review.assign
      # whose effect is refused when the provider group of the account the
      # reviewer's review would run on (ProviderRule.review_provider) has
      # built the task (ProviderRecord). Otherwise it changes nothing, and
      # review.assign writes no row for it (RC-15). It reads only.
      module RefuseReviewerOfBuildingProvider
        REASON = "This agent's account is with a provider that built the task.".freeze

        module_function

        def call(version:, request:, task:)
          seat = Seat.find_by!(workspace_id: request.workspace_id, id: request.subject_id)
          built = ProviderRecord.groups(task.id).include?(ProviderRecord.group(ProviderRule.review_provider(seat)))
          AppCheckers::Result.new(result: "applied", reason: (REASON if built), effect: ("refused" if built))
        end
      end
    end
  end
end
