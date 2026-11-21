require "test_helper"

# The handoff to WP4 (milestone 5 plan §4).
class WP4StubsTest < ActiveSupport::TestCase
  test "Actions.create_for provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :create_for
    assert_nil stub.create_for(nil, nil)
  end

  test "Actions.request_all provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :request_all
    assert_nil stub.request_all(nil, nil)
  end

  test "Actions.approve provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :approve
    assert_nil stub.approve(nil, nil, by: nil, rule_check: nil)
  end

  test "Actions.stop provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :stop
    assert_nil stub.stop(nil, nil, by: nil, rule_check: nil, reason: nil)
  end

  test "Actions.start provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :start
    assert_nil stub.start(nil, nil)
  end

  test "Actions.report_done provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :report_done
    assert_nil stub.report_done(nil, nil)
  end

  test "Actions.mark_done provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :mark_done
    assert_nil stub.mark_done(nil, nil)
  end

  test "Actions.waive provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :waive
    assert_nil stub.waive(nil, nil)
  end

  test "Actions.withdraw_open provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :withdraw_open
    assert_nil stub.withdraw_open(nil, nil)
  end

  test "Actions.revoke_open provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :revoke_open
    assert_nil stub.revoke_open(nil, nil)
  end

  test "Actions.record_overturn provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :record_overturn
    assert_nil stub.record_overturn(nil, nil)
  end

  test "Actions.approvals_complete? provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :approvals_complete?
    assert_equal false, stub.approvals_complete?(nil)
  end

  test "Actions.last_open? provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :last_open?
    assert_equal false, stub.last_open?(nil)
  end

  test "Actions.any_started? provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :any_started?
    assert_equal false, stub.any_started?(nil)
  end

  test "Actions.first_approved_open provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :first_approved_open
    assert_nil stub.first_approved_open(nil)
  end

  test "Actions.stopped_by_check? provides its handoff answer" do
    stub = "Leverage::Actions".safe_constantize
    assert stub, "Leverage::Actions is defined"
    assert_respond_to stub, :stopped_by_check?
    assert_equal false, stub.stopped_by_check?(nil)
  end

  test "Finishing.settle provides its handoff answer" do
    stub = "Leverage::Finishing".safe_constantize
    assert stub, "Leverage::Finishing is defined"
    assert_respond_to stub, :settle
    assert_nil stub.settle(nil, nil, by: nil)
  end

  test "Finishing.reenter_action provides its handoff answer" do
    stub = "Leverage::Finishing".safe_constantize
    assert stub, "Leverage::Finishing is defined"
    assert_respond_to stub, :reenter_action
    assert_nil stub.reenter_action(nil, nil, nil)
  end

  test "Finishing.after_command provides its handoff answer" do
    stub = "Leverage::Finishing".safe_constantize
    assert stub, "Leverage::Finishing is defined"
    assert_respond_to stub, :after_command
    assert_nil stub.after_command(nil)
  end

  test "Finishing.builder_free? provides its handoff answer" do
    stub = "Leverage::Finishing".safe_constantize
    assert stub, "Leverage::Finishing is defined"
    assert_respond_to stub, :builder_free?
    assert_equal false, stub.builder_free?(nil)
  end

  test "Finishing.builder_holds_task? provides its handoff answer" do
    stub = "Leverage::Finishing".safe_constantize
    assert stub, "Leverage::Finishing is defined"
    assert_respond_to stub, :builder_holds_task?
    assert_equal false, stub.builder_holds_task?(nil)
  end

  test "Finishing.waiting_for provides its handoff answer" do
    stub = "Leverage::Finishing".safe_constantize
    assert stub, "Leverage::Finishing is defined"
    assert_respond_to stub, :waiting_for
    assert_equal [], stub.waiting_for(nil)
  end

  test "Finishing.lose_builder provides its handoff answer" do
    stub = "Leverage::Finishing".safe_constantize
    assert stub, "Leverage::Finishing is defined"
    assert_respond_to stub, :lose_builder
    assert_nil stub.lose_builder(nil, nil, cause: nil)
  end

  test "Transitions::Gate.request_action provides its handoff answer" do
    stub = "Leverage::Transitions::Gate".safe_constantize
    assert stub, "Leverage::Transitions::Gate is defined"
    assert_respond_to stub, :request_action
    assert_nil stub.request_action(nil, nil)
  end

  test "Transitions::Gate.reenter_action provides its handoff answer" do
    stub = "Leverage::Transitions::Gate".safe_constantize
    assert stub, "Leverage::Transitions::Gate is defined"
    assert_respond_to stub, :reenter_action
    assert_nil stub.reenter_action(nil, nil, nil)
  end

  test "JobInputs::Approval.call provides its handoff answer" do
    stub = "Leverage::JobInputs::Approval".safe_constantize
    assert stub, "Leverage::JobInputs::Approval is defined"
    assert_respond_to stub, :call
    error = assert_raises(NotImplementedError) { stub.call(nil, nil) }
    assert_equal "not built yet", error.message
  end

  test "JobResults::Approval.check_shape provides its handoff answer" do
    stub = "Leverage::JobResults::Approval".safe_constantize
    assert stub, "Leverage::JobResults::Approval is defined"
    assert_respond_to stub, :check_shape
    error = assert_raises(NotImplementedError) { stub.check_shape(nil, nil) }
    assert_equal "not built yet", error.message
  end

  test "JobResults::Approval.refusals provides its handoff answer" do
    stub = "Leverage::JobResults::Approval".safe_constantize
    assert stub, "Leverage::JobResults::Approval is defined"
    assert_respond_to stub, :refusals
    assert_equal [], stub.refusals(nil)
  end

  test "JobResults::Approval.perform provides its handoff answer" do
    stub = "Leverage::JobResults::Approval".safe_constantize
    assert stub, "Leverage::JobResults::Approval is defined"
    assert_respond_to stub, :perform
    error = assert_raises(NotImplementedError) { stub.perform(nil, nil, nil, seat: nil, answer: nil, tokens: nil, spend: nil) }
    assert_equal "not built yet", error.message
  end
end
