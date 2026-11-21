require "test_helper"

class JobInputsApprovalTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(role: "orchestrator")
    @task = @scenario.finishing_task(holder: false, actions: [ { kind: "send", description: "Sample notice" } ])
    @action = Action.find_by!(task_id: @task.id)
    @rule = @scenario.rule(hook: "action.requested", kind: "policy")
    @check = @scenario.rule_check(@task, rule: @rule, subject: @action, attempts: 0)
    @other = @scenario.task(state: "backlog", title: "Unrelated sample")
  end

  test "an approval claim carries its own action and contract material" do
    create_job(state: "queued")
    result = apply("claim_job", {})
    assert_equal :completed, result.outcome
    input = result.result.fetch("input")
    assert_equal @action.id, input.fetch("action_id")
    assert_equal "Sample notice", input.dig("material", "action", "description")
    assert_equal @task.title, input.dig("material", "contract", "title")
    refute_includes input.to_json, @other.title
  end

  %w[approve stop pass_to_owner].each do |decision|
    test "records the approval result #{decision}" do
      job = create_job(state: "claimed")
      result = submit(job, decision)
      assert_equal :completed, result.outcome
      assert_equal "applied", @check.reload.result
      assert_equal({ "approve" => "approved", "stop" => "stopped", "pass_to_owner" => "passed_to_owner" }.fetch(decision),
        @check.effect)
      assert_equal({ "approve" => "approved", "stop" => "stopped", "pass_to_owner" => "requested" }.fetch(decision),
        @action.reload.state)
      assert Hold.exists?(task_id: @task.id, reason: "owner_approval") if decision == "pass_to_owner"
    end
  end

  test "a withdrawn approval job cannot decide again" do
    job = create_job(state: "withdrawn")
    result = submit(job, "approve")
    assert_equal :refused, result.outcome
    assert_equal "invalid_state", result.refusal.code
    assert_equal "requested", @action.reload.state
  end

  test "the second queue miss passes to the owner and cannot be re-run" do
    job = create_job(state: "queued", attempt_number: 2, queued_at: @scenario.database_now - 30.minutes)
    Leverage::Sweep.timer(@scenario.workspace_id, "check_queue_timeout", "job_id" => job.id)
    assert_equal "error", @check.reload.result
    assert_equal [ "owner_approval" ], Leverage::Holds.open_holds(@task).map(&:reason)
    result = apply("rerun_check", { "id" => @check.id }, caller: @scenario.owner)
    assert_equal "invalid_state", result.refusal&.code
  end

  private

  def create_job(state:, attempt_number: 1, queued_at: @scenario.database_now)
    job = @scenario.job(kind: "approval", task: @task, target: @check, state: state, seat: @seat,
      attempt_number: attempt_number)
    RuleCheckAttempt.create!(workspace_id: @task.workspace_id, rule_check_id: @check.id, job_id: job.id,
      attempt_number: attempt_number, queued_at: queued_at, started_at: (job.claimed_at if state == "claimed"))
    job
  end

  def submit(job, decision)
    apply("submit_job_result", { "id" => job.id, "result" => { "decision" => decision, "reason" => "Sample reason" },
      "tokens" => 1, "spend" => 0 })
  end

  def apply(command, params, caller: @seat)
    Leverage::Transitions.apply(Leverage::Transitions::Request.new(command: command, workspace_id: @task.workspace_id,
      caller_kind: caller.is_a?(User) ? "owner" : "seat", caller_id: caller.id, key: SecureRandom.uuid,
      request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end
end
