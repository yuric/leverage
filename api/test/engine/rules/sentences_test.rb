require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::Sentences (PRD L344; milestone 4 plan RD-62): one fixed sentence
    # per checker_function, filled from the version's parameters. It is the
    # Settings sentence and, in a briefing, the instruction of an app rule;
    # a model rule's text is its instruction, so it has none.
    class SentencesTest < ActiveSupport::TestCase
      include TestSupport

      def shipped(key) = scenario.current_version(scenario.rule(key: key, origin: "shipped"))

      test "the acceptance criteria rule's sentence names its minimum count" do
        assert_equal "Every task needs at least 1 acceptance criterion besides the review.",
          Sentences.for(shipped("acceptance_criteria"))
        assert_equal "Every task needs at least 3 acceptance criteria besides the review.",
          Sentences.for_function("minimum_criteria_count", { "minimum_count" => 3 })
        assert_equal "Every task needs at least 0 acceptance criteria besides the review.",
          Sentences.for_function("minimum_criteria_count", { "minimum_count" => 0 })
      end

      test "the provider rule's sentence" do
        assert_equal "An agent on a provider that built the task may not review it.",
          Sentences.for(shipped("different_provider_review"))
      end

      test "the three functions that do not act yet have sentences for Settings" do
        assert_equal "Workers ask the orchestrator before they ask you.", Sentences.for(shipped("ask_orchestrator_first"))
        assert_equal "After 2 failed reviews a task moves to a stronger model.",
          Sentences.for(shipped("escalate_after_failed_reviews"))
        assert_equal "After 1 failed review a task moves to a stronger model.",
          Sentences.for_function("escalate_after_failed_reviews", { "threshold" => 1 })
        assert_equal "A project pauses when it reaches its budget.", Sentences.for(shipped("project_budget_pause"))
      end

      test "every function of the shipped rules has a sentence, and a model rule has none" do
        Shipped.all.each do |record|
          version = shipped(record.key)
          if record.checker == "app"
            assert_kind_of String, Sentences.for(version), record.key
          else
            assert_nil Sentences.for(version), record.key
          end
        end
      end

      test "an unknown function is a mistake" do
        assert_raises(KeyError) { Sentences.for_function("made_up_function", {}) }
      end
    end
  end
end
