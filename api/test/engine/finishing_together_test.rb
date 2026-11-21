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

  test "jobs queued together are claimed in enqueue order" do
    task = @scenario.task(state: "working", builder: @builder)
    first_target = @scenario.question(task, blocking: false)
    second_target = @scenario.question(task, blocking: false)
    ctx = @scenario.context
    first = Leverage::Jobs.queue(ctx, kind: "question", task: task, target: first_target, seat_role: "orchestrator",
      input: {}, id: "ffffffff-ffff-4fff-8fff-ffffffffffff")
    second = Leverage::Jobs.queue(ctx, kind: "question", task: task, target: second_target, seat_role: "orchestrator",
      input: {}, id: "00000000-0000-4000-8000-000000000001")

    assert_equal first.queued_at, second.queued_at
    assert_equal first.id, seat("claim_job", @orchestrator).result.fetch("job_id")
  end

  [ nil, "Use the owner's sample instruction." ].each do |instruction|
    test "an approval job uses #{instruction ? 'the edited' : 'the shipped'} instruction" do
      key = "orchestrator_approves_actions"
      @scenario.rule(key: key, origin: "shipped", instruction: instruction)
      pass_review("send")

      claimed = seat("claim_job", @orchestrator)
      assert claimed.completed?
      expected = instruction || Leverage::Rules::Shipped.find(key).version_fields.fetch(:instruction)
      assert expected == claimed.result.dig("input", "material", "instruction")
    end
  end

  test "a contract draft takes the brief in its edited order" do
    project = @scenario.project
    task = @scenario.task(project: project)
    planner = @scenario.planner
    entries = [
      { "kind" => "fact", "text" => "Sample fact one" },
      { "kind" => "fact", "text" => "Sample fact two" }
    ]
    assert owner("edit_brief", project, "entries" => entries).completed?
    assert owner("edit_brief", project, "entries" => entries.reverse).completed?
    assert owner("draft_contract", task).completed?

    claimed = seat("claim_job", planner)
    assert claimed.completed?
    assert_equal entries.reverse.pluck("text"), claimed.result.dig("input", "material", "brief").pluck("text")
  end

  [ false, true ].each do |claimed|
    test "a #{claimed ? 'claimed' : 'queued'} job cannot repopulate deleted content" do
      @scenario.rule(hook: "task.before_done", on_fail: "warn")
      task = pass_review
      job = Job.find_by!(task_id: task.id, kind: "rule_check")
      assert_equal job.id, seat("claim_job", @orchestrator).result.fetch("job_id") if claimed
      assert apply("delete_content", "owner", @scenario.owner, "task_id" => task.id).completed?

      if claimed
        result = seat("submit_job_result", @orchestrator, "id" => job.id, "tokens" => 1, "spend" => 0,
          "result" => { "result" => "passed", "reason" => "Sample reason" })
        assert_equal "invalid_state", result.refusal&.code
      else
        assert_equal "not_eligible", seat("claim_job", @orchestrator).refusal&.code
      end
      assert_nil job.reload.result
      assert_nil RuleCheck.find(job.target_id).reason
    end
  end

  test "routing credits question job time, tokens and spend to its policy" do
    rule = @scenario.rule(key: "ask_orchestrator_first", origin: "shipped")
    task = @scenario.task(state: "working", builder: @builder)
    acknowledge(task)
    asked = seat("ask_question", @builder, "id" => task.id, "text" => "Sample question?",
      "assumption" => "Sample assumption", "blocking" => false)
    assert asked.completed?
    job_id = seat("claim_job", @orchestrator).result.fetch("job_id")
    assert seat("submit_job_result", @orchestrator, "id" => job_id, "tokens" => 37, "spend" => 0.25,
      "result" => { "outcome" => "answered", "basis" => "record", "answer" => "Sample answer" }).completed?

    job = Job.find(job_id)
    timing = Leverage::Reads::RuleTiming.call(@scenario.workspace_id, rule_id: rule.id).sole
    assert_equal [ 1, 37, 0.25 ], timing.values_at("attempts", "tokens", "spend")
    assert_equal({ "applied" => 1 }, timing.fetch("results"))
    assert_in_delta (job.claimed_at - job.queued_at), timing.fetch("queue_seconds"), 0.000_001
    assert_in_delta (job.finished_at - job.claimed_at), timing.fetch("run_seconds"), 0.000_001
    stats = Leverage::Reads::Rules.call(@scenario.workspace_id).fetch(:rules).sole.fetch(:stats)
    assert_equal [ 1, 37, 0.25 ], stats.values_at(:checks, :tokens, :spend)
  end

  test "a released and offered action gets a fresh briefing before it can start" do
    task = pass_review("send")
    action = Action.find_by!(task_id: task.id)
    assert owner("approve_action", action).completed?
    assert_equal "action", Leverage::Reads::NextItem.call(@builder).fetch("kind")
    acknowledge(task)
    original = task.reload.lease_due_at

    assert seat("release", @builder, "id" => task.id, "reason" => "unable_to_continue").completed?
    released = event(task, "task.released")
    unconfirmed = event(task, "hold.opened")
    assert_equal released.id, unconfirmed.cause_id

    assert owner("offer_task_again", task).completed?
    assert_equal @builder.id, event(task, "hold.closed").payload.fetch("lease_seat_id")
    assert_operator task.reload.lease_due_at, :>, original
    assert_nil task.resume_pending_since
    assert_equal "action", Leverage::Reads::NextItem.call(@builder).fetch("kind")
    assert_equal "briefing_not_acknowledged", action_call("start_action", task, action).refusal&.code
    acknowledge(task)
    assert action_call("start_action", task, action).completed?
    assert action_call("report_action_done", task, action).completed?
    assert_equal "done", task.reload.state
  end

  %w[change_seat remove_seat].each do |command|
    test "#{command} opens a second hold for the approved action under an owner hold" do
      task = pass_review("send")
      action = Action.find_by!(task_id: task.id)
      assert owner("approve_action", action).completed?
      assert owner("hold", task, "note" => "Sample pause").completed?
      assert owner(command, @builder, (command == "change_seat" ? { "enabled" => false } : {})).completed?
      holds = Leverage::Holds.open_holds(task)
      assert_equal %w[action_unconfirmed owner_hold], holds.map(&:reason).sort
      unconfirmed = holds.find { |hold| hold.reason == "action_unconfirmed" }
      item = Leverage::Reads::Inbox.call(@scenario.workspace_id).fetch(:items).find { |row| row[:hold_id] == unconfirmed.id }
      refute_includes item.fetch(:choices), "offer_again"
      assert owner("resume", task).completed?
      assert_equal [ "action_unconfirmed" ], Leverage::Holds.open_holds(task).map(&:reason)
      assert_equal @builder.id, task.reload.holder_seat_id
      assert_equal "invalid_state", owner("offer_task_again", task).refusal&.code
    end
  end

  test "the action lease follows the previous builder as soon as other work is released" do
    task = pass_review("send")
    occupied = @scenario.task(state: "working", builder: @builder)
    action = Action.find_by!(task_id: task.id)
    assert owner("approve_action", action).completed?
    assert_nil task.reload.holder_seat_id
    assert_nil event(task, "action.approved").payload.fetch("lease_seat_id")

    assert seat("release", @builder, "id" => occupied.id, "reason" => "unable_to_continue").completed?

    assert_equal @builder.id, task.reload.holder_seat_id
    granted = event(task, "action.lease_granted")
    assert_equal @builder.id, granted.payload.fetch("lease_seat_id")
    assert_equal event(occupied, "task.released").id, granted.cause_id
    assert_equal "action", Leverage::Reads::NextItem.call(@builder).fetch("kind")
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
    assert_equal(kinds.empty? ? "done" : "finishing", task.reload.state)
    task
  end

  def acknowledge(task)
    assert seat("acknowledge_briefing", @builder, "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: @builder)).completed?
  end

  def action_call(command, task, action)
    seat(command, @builder, "id" => task.id, "aid" => action.id)
  end

  def event(task, type)
    Event.where(task_id: task.id, type: type).order(:seq).last
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
