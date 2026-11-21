module Leverage
  module Rules
    # One fixed sentence per checker_function (PRD L344; milestone 4 plan
    # RD-62), filled from a version's parameters: the sentence Settings
    # shows for an app rule and, in a briefing, its instruction. A model
    # rule's text is its instruction, so it has none here.
    module Sentences
      SENTENCES = {
        "minimum_criteria_count" => lambda do |parameters|
          count = Integer(parameters.fetch("minimum_count", 1))
          "Every task needs at least #{count} acceptance #{count == 1 ? "criterion" : "criteria"} besides the review."
        end,
        "refuse_reviewer_of_building_provider" => ->(_) { "An agent on a provider that built the task may not review it." },
        "route_question" => ->(_) { "Agents ask the agent that checks tasks before they ask you." },
        "escalate_after_failed_reviews" => lambda do |parameters|
          threshold = Integer(parameters.fetch("threshold", 2))
          "After #{threshold} failed #{threshold == 1 ? "review" : "reviews"} a task goes to a stronger agent."
        end,
        "pause_project_at_budget" => lambda do |_|
          "A project pauses when its reported spending reaches its budget, and a task when it reaches its own limit."
        end
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
