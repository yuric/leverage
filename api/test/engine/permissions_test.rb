require "test_helper"
require_relative "gate_support"

class PermissionsTest < ActiveSupport::TestCase
  include GateSupport

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(role: "general", provider: "codex")
  end

  def offer = Leverage::Reads::NextItem.call(@seat)["kind"]

  test "Work off stops new claims and online presence, while Deliver off still offers reviews and jobs" do
    @scenario.task(state: "ready")
    @seat.update!(may_deliver: false)
    assert_equal "none", offer
    assert_equal "not_eligible", command("claim", @seat).refusal.code
    @scenario.task(state: "in_review")
    assert_equal "review", offer
    @scenario.job(kind: "contract_draft", task: @scenario.task)
    assert_equal "job", offer

    @seat.update!(may_work: false, may_deliver: true, last_polled_at: Time.current)
    assert_equal "none", offer
    %w[claim claim_review claim_job].each do |name|
      assert_equal "not_eligible", command(name, @seat).refusal.code
    end
    refute Leverage::RolePresence.online?(@scenario.workspace, "orchestrator", Time.current)
  end

  test "a holder with Work off still heartbeats and delivers, but cannot submit with Deliver off" do
    task = ready_to_submit(@seat)
    @seat.update!(may_work: false, may_deliver: false)
    assert_equal "forbidden", command("submit", @seat, submit_params(task)).refusal.code
    @seat.update!(may_deliver: true)
    assert command("heartbeat", @seat, { "id" => task.id }).completed?
    assert command("submit", @seat, submit_params(task)).completed?
  end

  %i[may_work may_deliver].each do |permission|
    test "a failed review sends the task to Ready with #{permission} off" do
      reviewer = @scenario.seat(role: "reviewer")
      task, review = ready_for_verdict(@seat, reviewer)
      @seat.update!(permission => false)
      body = pass_params(review).merge("verdict" => "failed", "failed_criteria" => [ Criterion.find_by!(task_id: task.id, kind: "build").id ])
      assert command("fail_review", reviewer, body).completed?
      assert_equal [ "ready", nil ], task.reload.attributes.values_at("state", "holder_seat_id")
    end

    test "an action lease is granted with #{permission} off and returning it for rework goes to Ready" do
      @seat.update!(permission => false)
      task = @scenario.finishing_task(builder: @seat, holder: false, actions: [ { kind: "send", state: "approved" } ])
      Leverage::Finishing.after_command(@scenario.context)
      assert_equal @seat.id, task.reload.holder_seat_id
      assert command("return_for_rework", @scenario.owner, { "id" => task.id, "criterion_ids" => [] }).completed?
      assert_equal [ "ready", nil ], task.reload.attributes.values_at("state", "holder_seat_id")
    end
  end

  test "a builder without Deliver does not count as another builder, for escalation, or for account waits" do
    credential = @scenario.credential(provider: "claude")
    stronger = @scenario.seat(role: "builder", strength_rank: 5, credential: credential)
    credential.update!(limited_since: Time.current, limited_until: 1.hour.from_now)
    task = @scenario.task(state: "in_review", builder: stronger)
    @scenario.review(task, reviewer: @seat)
    refute Leverage::Eligibility.claim_standing?(@seat, task)
    stronger.update!(may_deliver: false)
    assert Leverage::Eligibility.claim_standing?(@seat, task)
    refute Leverage::Eligibility.standing?(stronger, task, rank: 5)
    ready = @scenario.task(state: "ready")
    @seat.update!(may_work: false)
    assert_nil Leverage::Candidates.wait_cause(ready, Time.current)
    assert_nil Leverage::Reads::Board::AccountWaits.new(@scenario.workspace_id, [ ready ]).for(ready)
  end
end
