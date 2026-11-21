module Leverage
  module Rules
    # The app checkers (PRD L336, L365; milestone 4 plan §2.1, RD-8): the
    # registry from a checker_function id to the class that runs it, and
    # the one list of what acts in this milestone. It reads only.
    #
    # Two of the five functions of shipped_rules.json are built. An app
    # rule whose function is not built does not run: it is in no request's
    # set, writes no row and is in no briefing. A model rule always runs
    # where a command reaches its hook; the approval rule's hook,
    # action.requested, and question.asked are reached by no command until
    # milestone 5, so the rules there do not act yet either (RD-8, §1.2).
    module AppCheckers
      # What a function answered: a gate's result (passed or failed) and
      # its reason, or a policy's applied result with its effect (nil when
      # it changes nothing). The reason is content: on the row only.
      Result = Data.define(:result, :reason, :effect)

      BUILT = {
        "minimum_criteria_count" => Checkers::MinimumCriteriaCount,
        "refuse_reviewer_of_building_provider" => Checkers::RefuseReviewerOfBuildingProvider
      }.freeze

      # Hooks no command reaches before milestone 5.
      LATER_HOOKS = %w[action.requested question.asked].freeze

      module_function

      def built?(function) = BUILT.key?(function)

      # Whether the version's checker can run: a model rule, or an app rule
      # whose function is built.
      def runs?(version)
        version.checker == "model" || built?(version.checker_function)
      end

      # Whether the rule has an effect in this milestone: Settings shows
      # the others as starting later, and briefings leave them out (RD-8).
      def acts?(version)
        runs?(version) && !LATER_HOOKS.include?(version.hook)
      end

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
