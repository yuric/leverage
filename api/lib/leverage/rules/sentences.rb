module Leverage
  module Rules
    # One fixed sentence per checker_function (PRD L344; milestone 4 plan
    # RD-62), filled from a version's parameters: the sentence Settings
    # shows for an app rule and, in a briefing, its instruction. A model
    # rule's text is its instruction, so it has none here. The three
    # functions that do not act yet have sentences for Settings only.
    module Sentences
      SENTENCES = {
        "minimum_criteria_count" => lambda do |parameters|
          count = Integer(parameters.fetch("minimum_count", 1))
          "Every task needs at least #{count} acceptance #{count == 1 ? "criterion" : "criteria"} besides the review."
        end,
        "refuse_reviewer_of_building_provider" => ->(_) { "An agent on a provider that built the task may not review it." },
        "route_question" => ->(_) { "Workers ask the orchestrator before they ask you." },
        "escalate_after_failed_reviews" => lambda do |parameters|
          threshold = Integer(parameters.fetch("threshold", 2))
          "After #{threshold} failed #{threshold == 1 ? "review" : "reviews"} a task moves to a stronger model."
        end,
        "pause_project_at_budget" => ->(_) { "A project pauses when it reaches its budget." }
      }.freeze

      module_function

      # The sentence of an app rule's version, or nil for a model rule.
      def for(version)
        return nil unless version.checker == "app"

        for_function(version.checker_function, version.parameters || {})
      end

      # Raises KeyError for a function with no sentence.
      def for_function(function, parameters)
        SENTENCES.fetch(function).call(parameters || {})
      end
    end
  end
end
