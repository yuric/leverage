require "test_helper"

# The handoff to WP6 (milestone 5 plan §4).
class WP6StubsTest < ActiveSupport::TestCase
  test "Questions.ask provides its handoff answer" do
    stub = "Leverage::Questions".safe_constantize
    assert stub, "Leverage::Questions is defined"
    assert_respond_to stub, :ask
    assert_nil stub.ask(nil, nil, text: nil, assumption: nil, blocking: nil)
  end

  test "Questions.route provides its handoff answer" do
    stub = "Leverage::Questions".safe_constantize
    assert stub, "Leverage::Questions is defined"
    assert_respond_to stub, :route
    assert_nil stub.route(nil, nil, nil)
  end

  test "Questions.answer provides its handoff answer" do
    stub = "Leverage::Questions".safe_constantize
    assert stub, "Leverage::Questions is defined"
    assert_respond_to stub, :answer
    assert_nil stub.answer(nil, nil, by: nil, text: nil, basis: nil)
  end

  test "Questions.pass_on provides its handoff answer" do
    stub = "Leverage::Questions".safe_constantize
    assert stub, "Leverage::Questions is defined"
    assert_respond_to stub, :pass_on
    assert_nil stub.pass_on(nil, nil)
  end

  test "Questions.overturn provides its handoff answer" do
    stub = "Leverage::Questions".safe_constantize
    assert stub, "Leverage::Questions is defined"
    assert_respond_to stub, :overturn
    assert_nil stub.overturn(nil, nil)
  end

  test "Transitions::MarkQuestionRead.call provides its handoff answer" do
    stub = "Leverage::Transitions::MarkQuestionRead".safe_constantize
    assert stub, "Leverage::Transitions::MarkQuestionRead is defined"
    assert_respond_to stub, :call
    assert_nil stub.call(nil)
  end

  test "JobInputs::Question.call provides its handoff answer" do
    stub = "Leverage::JobInputs::Question".safe_constantize
    assert stub, "Leverage::JobInputs::Question is defined"
    assert_respond_to stub, :call
    error = assert_raises(NotImplementedError) { stub.call(nil, nil) }
    assert_equal "not built yet", error.message
  end

  test "JobResults::Question.check_shape provides its handoff answer" do
    stub = "Leverage::JobResults::Question".safe_constantize
    assert stub, "Leverage::JobResults::Question is defined"
    assert_respond_to stub, :check_shape
    error = assert_raises(NotImplementedError) { stub.check_shape(nil, nil) }
    assert_equal "not built yet", error.message
  end

  test "JobResults::Question.refusals provides its handoff answer" do
    stub = "Leverage::JobResults::Question".safe_constantize
    assert stub, "Leverage::JobResults::Question is defined"
    assert_respond_to stub, :refusals
    assert_equal [], stub.refusals(nil)
  end

  test "JobResults::Question.perform provides its handoff answer" do
    stub = "Leverage::JobResults::Question".safe_constantize
    assert stub, "Leverage::JobResults::Question is defined"
    assert_respond_to stub, :perform
    error = assert_raises(NotImplementedError) { stub.perform(nil, nil, nil, seat: nil, answer: nil, tokens: nil, spend: nil) }
    assert_equal "not built yet", error.message
  end

  %w[question_job_queue_timeout question_job_run_timeout].each do |command|
    test "#{command} runs without a registered timer while pending" do
      scenario = Scenario.new
      before = scenario.workspace.reload.last_seq
      outcome = nil

      assert_nothing_raised { outcome = Leverage::Sweep.timer(scenario.workspace_id, command) }

      assert outcome.completed?
      assert_equal before, scenario.workspace.reload.last_seq
    end
  end
end
