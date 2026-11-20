require_relative "../rules_test_support"

module Leverage
  module Rules
    module Checkers
      # Checkers::RefuseReviewerOfBuildingProvider, the function of "A
      # different provider reviews every task" (PRD L441, L448; milestone 4
      # plan §2.1 rule 8, RD-50): a policy at review.assign whose effect is
      # refused when the provider group of the account the review would run
      # on has built the task, and that changes nothing otherwise.
      class RefuseReviewerOfBuildingProviderTest < ActiveSupport::TestCase
        include Leverage::Rules::TestSupport

        setup do
          rule = scenario.with_shipped_rules.find { |row| row.key == "different_provider_review" }
          @version = scenario.current_version(rule)
          @builder = scenario.seat(role: "builder", credential: scenario.credential(provider: "claude"))
          @task = scenario.task(state: "in_review", builder: @builder)
        end

        def check(reviewer)
          RefuseReviewerOfBuildingProvider.call(version: @version, task: @task,
            request: request_for(@task, "review.assign", subject: reviewer, requester: reviewer))
        end

        test "a reviewer whose account's provider built the task is refused" do
          reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude"))

          result = check(reviewer)
          assert_equal [ "applied", "refused" ], [ result.result, result.effect ]
          assert_equal "This agent's account is with a provider that built the task.", result.reason
        end

        test "an API token of the vendor that built the task is the same provider" do
          reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude_api", kind: "api_token"))

          assert_equal "refused", check(reviewer).effect
        end

        test "a reviewer on another provider changes nothing" do
          reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "codex"))

          result = check(reviewer)
          assert_equal "applied", result.result
          assert_nil result.effect
        end

        test "the account compared is the one the reviewer's run is on, or the seat's own provider when it connects on its own (RD-50)" do
          codex = scenario.credential(provider: "codex")
          reviewer = scenario.seat(role: "reviewer", credential: codex)
          scenario.run(reviewer, on: scenario.credential(provider: "claude"))
          assert_equal "refused", check(reviewer).effect

          on_its_own = scenario.seat(role: "reviewer", provider: "claude_api")
          assert_equal "refused", check(on_its_own).effect
          assert_nil check(scenario.seat(role: "reviewer", provider: "gemini")).effect
        end
      end
    end
  end
end
