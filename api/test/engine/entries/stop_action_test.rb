require "test_helper"
require_relative "request_action_test"

class StopActionTest < ActiveSupport::TestCase
  include OutwardActionCommands

  test "the owner stopping a requested action withdraws its queued check and job" do
    @scenario = Scenario.new
    @builder = @scenario.seat
    task, action = finishing_action("requested")
    rule = @scenario.rule(hook: "action.requested", on_fail: "block")
    check = @scenario.rule_check(task, rule: rule, subject: action)
    job = Job.find(RuleCheckAttempt.find_by!(rule_check_id: check.id).job_id)
    request = action_request("stop_action", caller: @scenario.owner, id: action.id)

    assert T.apply(request).completed?
    assert_equal "stopped", action.reload.state
    assert_equal "withdrawn", check.reload.result
    assert_equal "withdrawn", job.reload.state
    assert Hold.exists?(action_id: action.id, reason: "action_stopped", closed_at: nil)
  end
end
