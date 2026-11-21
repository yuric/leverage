require "test_helper"

class FinishingTogetherTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat
    @reviewer = @scenario.seat(role: "reviewer")
    @orchestrator = @scenario.orchestrator
    Leverage::Gating.implementation = Leverage::Rules::Engine.new
  end

  [ false, true ].each do |deferred|
    test "an out-of-scope approval goes to the owner #{deferred ? 'after its gate' : 'immediately'}" do
      policy = @scenario.rule(key: "orchestrator_approves_actions", origin: "shipped",
        scope_kind: "action_kinds", scope_values: [ "publish" ])
      gate = @scenario.rule(hook: "action.requested") if deferred
      task = pass_review("send")
      action = Action.find_by!(task_id: task.id)

      if deferred
        assert_equal "invalid_state", owner("approve_action", action).refusal.code
        job = seat("claim_job", @orchestrator).result.fetch("job_id")
        assert_equal gate.id, RuleCheck.find(Job.find(job).target_id).rule_id
        assert seat("submit_job_result", @orchestrator, "id" => job,
          "result" => { "result" => "passed", "reason" => "Sample result" }, "tokens" => 0, "spend" => 0).completed?
      end

      assert_equal "not_applicable", RuleCheck.find_by!(subject_id: action.id, rule_id: policy.id).result
      assert_empty Job.where(task_id: task.id, kind: "approval")
      assert Hold.exists?(action_id: action.id, reason: "owner_approval", closed_at: nil)
      assert owner("approve_action", action).completed?
      assert_equal @builder.id, task.reload.holder_seat_id
      assert_equal "approved", action.reload.state
    end
  end

  private

  def pass_review(*kinds)
    task = @scenario.task(state: "in_review", builder: @builder, reviewer: @reviewer,
      actions: kinds.map { |kind| { kind: kind, description: "Sample action" } })
    review = @scenario.review(task, reviewer: @reviewer)
    assert seat("acknowledge_review_briefing", @reviewer, "id" => review.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: @reviewer, review: review)).completed?
    assert seat("pass_review", @reviewer, "id" => review.id, "verdict" => "passed",
      "failed_criteria" => [], "notes" => "Sample review", "tokens" => 0, "spend" => 0).completed?
    assert_equal "finishing", task.reload.state
    task
  end

  def owner(command, target, params = {})
    apply(command, "owner", @scenario.owner, params.merge("id" => target.id))
  end

  def seat(command, caller, params = {})
    apply(command, "seat", caller, params)
  end

  def apply(command, kind, caller, params)
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id,
      caller_kind: kind, caller_id: caller.id, key: SecureRandom.uuid,
      request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end
end
