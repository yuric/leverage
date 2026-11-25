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

  test "a waiting review opens No reviewer is eligible when the last reviewer cannot work" do
    @scenario.rule(key: "different_provider_review", origin: "shipped")
    task = @scenario.task(state: "in_review")
    Leverage::ReviewerEligibility.reevaluate(@scenario.context)
    refute InboxItem.exists?(about_id: task.id, kind: "no_reviewer_eligible")
    @seat.update!(may_work: false)
    Leverage::ReviewerEligibility.reevaluate(@scenario.context)
    assert InboxItem.exists?(about_id: task.id, kind: "no_reviewer_eligible", state: "open")
  end

  test "a stronger seat without Deliver does not trigger escalation" do
    rule = @scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped", parameters: { "threshold" => 1 })
    task = @scenario.task(state: "in_review", builder: @seat)
    review = Review.find_by!(task_id: task.id)
    stronger = @scenario.seat(strength_rank: 2, may_deliver: false)
    request = Leverage::Gating::Request.new(subject_id: review.id, subject_kind: "review", workspace_id: task.workspace_id,
      hook: "review.failed", task_id: task.id, project_id: task.project_id, round: task.round, inputs: {},
      requester_kind: "seat", requester_id: @seat.id, command_key: "escalation")
    check = -> { Leverage::Rules::Checkers::EscalateAfterFailedReviews.call(version: @scenario.current_version(rule), request: request, task: task) }
    assert_nil check.call.effect
    stronger.update!(may_deliver: true)
    assert_equal "escalated", check.call.effect
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

    %w[approve_action offer_task_again mark_action_done].each do |operation|
      test "#{operation} leases approved actions to their builder with #{permission} off" do
        @seat.update!(permission => false)
        states = operation == "approve_action" ? %w[requested] : %w[approved approved]
        task = @scenario.finishing_task(builder: @seat, holder: false, actions: states.map { |state| { kind: "send", state: state } })
        actions = Action.where(task_id: task.id).order(:position)
        if operation == "approve_action"
          Leverage::Holds.open(@scenario.context, task: task, reason: "owner_approval", action_id: actions.first.id,
            facts: { action_id: actions.first.id })
        else
          @scenario.hold(task, reason: "action_unconfirmed", facts: { action_ids: actions.ids,
            approved_by_kind: "owner", approved_by_id: @scenario.owner.id, builder_announced_start: false })
        end
        target = operation == "offer_task_again" ? task : actions.first
        assert command(operation, @scenario.owner, { "id" => target.id }).completed?
        assert_equal @seat.id, task.reload.holder_seat_id
      end
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
    stronger.update!(may_deliver: true)
    assert_equal "credential_limit", Leverage::Candidates.wait_cause(ready, Time.current)
    credential.update!(state: "signed_out")
    assert_equal [ credential.id, nil ], Leverage::Reads::Board::AccountWaits.new(@scenario.workspace_id, [ ready ]).for(ready)
    stronger.update!(may_deliver: false)
    assert_nil Leverage::Reads::Board::AccountWaits.new(@scenario.workspace_id, [ ready ]).for(ready)
  end
end
