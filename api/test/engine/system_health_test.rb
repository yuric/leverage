require "test_helper"

class GeneralSystemHealthTest < CommittingTestCase
  test "the health line goes from not_set_up to online when a General seat begins polling" do
    assert_equal "not_set_up", orchestrator_status

    general = scenario.seat(role: "general")
    assert_equal "offline", orchestrator_status

    assert Leverage::Transitions::RecordPoll.seat(general)
    assert_equal "online", orchestrator_status
  end

  private

  def orchestrator_status = Leverage::Reads::SystemHealth.call(scenario.workspace_id).fetch(:orchestrator)
end
