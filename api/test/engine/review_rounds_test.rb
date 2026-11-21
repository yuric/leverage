require "test_helper"

class ReviewRoundsTest < ActiveSupport::TestCase
  test "only failed verdicts of this task count, including a failed before-done gate" do
    scenario = Scenario.new
    task = scenario.task
    other = scenario.task
    rule = scenario.rule(hook: "task.before_done")
    check = scenario.rule_check(task, rule: rule, result: "failed")
    task.update!(round: 4)

    reviews = Review.where(workspace_id: scenario.workspace_id, task_id: task.id)
    reviews.create!(round: 0, verdict: "failed")
    reviews.create!(round: 1, verdict: "failed", failed_rule_check_id: check.id)
    reviews.create!(round: 2, verdict: "passed")
    reviews.create!(round: 4)
    Review.create!(workspace_id: scenario.workspace_id, task_id: other.id, round: 0, verdict: "failed")

    assert_equal 2, Leverage::ReviewRounds.failed_count(task)
  end
end
