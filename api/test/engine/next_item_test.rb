require "test_helper"

class GeneralNextItemTest < ActiveSupport::TestCase
  test "an idle General seat gets a job before a review before a task" do
    scenario = Scenario.new
    general = scenario.seat(role: "general")
    scenario.task(state: "ready")
    scenario.task(state: "in_review")
    job = scenario.job(kind: "contract_draft", task: scenario.task)
    next_kind = -> { Leverage::Reads::NextItem.call(general).fetch("kind") }

    assert_equal "job", next_kind.call
    job.update!(state: "withdrawn", finished_at: scenario.database_now)
    assert_equal "review", next_kind.call
    Review.where(workspace_id: scenario.workspace_id).update_all(verdict: "passed")
    assert_equal "task", next_kind.call
  end
end
