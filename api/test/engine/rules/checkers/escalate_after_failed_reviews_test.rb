require_relative "../rules_test_support"

module Leverage
  module Rules
    class EscalateAfterFailedReviewsTest < ActiveSupport::TestCase
      include TestSupport

      def evaluate(task, review)
        Gating.evaluate(request_for(task, "review.failed", subject: review))
      end

      def task_with_review(rank: 1)
        builder = scenario.seat(strength_rank: rank)
        task = scenario.task(state: "in_review", builder: builder)
        [ task, Review.find_by!(task_id: task.id) ]
      end

      def assert_escalated(task, review)
        evaluation = evaluate(task, review)
        assert_equal [ [ "applied", "escalated" ] ], evaluation.checks.map { |check| [ check.result, check.effect ] }
        assert_equal [ "escalated" ], evaluation.effects.map(&:effect)
        assert_empty evaluation.jobs
      end

      def assert_no_escalation(task, review)
        evaluation = evaluate(task, review)
        assert_empty evaluation.checks
        assert_empty evaluation.effects
      end

      test "actual failed reviews count and the incoming failure counts once" do
        scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped")
        scenario.seat(strength_rank: 2)
        task, review = task_with_review
        task.update!(round: 3)
        assert_no_escalation task, review

        Review.create!(workspace_id: task.workspace_id, task_id: task.id, round: 2, verdict: "failed")
        assert_escalated task, review
        review.update!(verdict: "failed")
        assert_escalated task, review
      end

      test "a threshold of one can escalate to any enabled stronger builder" do
        scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped", parameters: { "threshold" => 1 })
        task, review = task_with_review
        scenario.seat(strength_rank: 3)

        assert_escalated task, review
      end

      test "disabled and removed seats, other roles and other workspaces cannot take the rework" do
        scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped", parameters: { "threshold" => 1 })
        task, review = task_with_review
        scenario.seat(strength_rank: 2, enabled: false)
        scenario.seat(strength_rank: 3).update!(removed_at: scenario.database_now)
        scenario.seat(role: "reviewer", strength_rank: 3)
        Scenario.new.seat(strength_rank: 3)

        assert_no_escalation task, review
      end

      test "no escalation is recorded when the builder already has the highest rank" do
        scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped", parameters: { "threshold" => 1 })
        task, review = task_with_review(rank: 3)
        scenario.seat(strength_rank: 3)

        assert_no_escalation task, review
      end

      test "a stronger General seat that has never reviewed the task counts for escalation" do
        scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped", parameters: { "threshold" => 1 })
        task, review = task_with_review
        scenario.seat(role: "general", strength_rank: 2)
        assert_escalated task, review
      end

      test "a stronger General seat that reviewed the task cannot trigger escalation on the second failure" do
        scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped")
        task, first_review = task_with_review
        general = scenario.seat(role: "general", strength_rank: 2)
        scenario.review(task, reviewer: general)
        first_review.reload.update!(verdict: "failed", lease_due_at: nil)
        task.update!(round: 1)
        review = Review.create!(workspace_id: task.workspace_id, task_id: task.id, round: 1, reviewer_seat_id: general.id)

        assert_no_escalation task, review
        dedicated = scenario.seat(role: "builder", strength_rank: 2)
        assert_escalated task, review
        scenario.task(state: "working", builder: dedicated)
        assert_escalated task, review
        dedicated.update!(paused: true)
        assert_escalated task, review
      end

      test "the disabled rule writes no row even when a stronger builder can take the work" do
        scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped", enabled: false, parameters: { "threshold" => 1 })
        task, review = task_with_review
        scenario.seat(strength_rank: 2)

        assert_no_escalation task, review
      end
    end
  end
end
