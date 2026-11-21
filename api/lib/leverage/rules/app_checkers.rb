module Leverage
  module Rules
    # Maps each app checker function to the code that runs it. All five
    # shipped functions are available (AP-1). It reads only.
    module AppCheckers
      # What a function answered: a gate's result (passed or failed) and
      # its reason, or a policy's applied result with its effects. A policy
      # can plan multiple effects for one check. The reason is content.
      Result = Data.define(:result, :reason, :effect)

      BUILT = {
        "minimum_criteria_count" => Checkers::MinimumCriteriaCount,
        "refuse_reviewer_of_building_provider" => Checkers::RefuseReviewerOfBuildingProvider,
        "route_question" => Checkers::RouteQuestion,
        "pause_project_at_budget" => Checkers::PauseProjectAtBudget,
        "escalate_after_failed_reviews" => Checkers::EscalateAfterFailedReviews
      }.freeze

      module_function

      def built?(function) = BUILT.key?(function)

      # Whether the version's checker can run: a model rule, or an app rule
      # whose function is built.
      def runs?(version)
        version.checker == "model" || built?(version.checker_function)
      end

      def acts?(version) = runs?(version)

      # Runs the version's function on the request, inside the command.
      #
      # Returns a Result. Raises ArgumentError for a function not built.
      def check(version, request:, task:)
        checker = BUILT[version.checker_function] ||
          raise(ArgumentError, "the app checker #{version.checker_function.inspect} is not built")
        checker.call(version: version, request: request, task: task)
      end
    end
  end
end
