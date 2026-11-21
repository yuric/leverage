require "test_helper"

class GateActionsTest < ActiveSupport::TestCase
  G = Leverage::Gating
  Gate = Leverage::Transitions::Gate

  setup do
    @scenario = Scenario.new
    @task = @scenario.finishing_task(holder: false, actions: [ { kind: "send", description: "Sample notice" } ])
    @action = Action.find_by!(task_id: @task.id)
    @policy = setup_rule("policy", "model")
  end

  test "a blocking failed gate stops the action without planning an approval" do
    failed = setup_rule("gate", "app", app_result: "failed")
    G.implementation = G::StandIn.new(rules: [ failed, @policy ])
    ctx = @scenario.context

    Gate.request_action(ctx, @action)

    assert_equal "stopped", @action.reload.state
    assert_empty Job.where(task_id: @task.id, kind: "approval")
    hold = Hold.find_by!(task_id: @task.id, reason: "action_stopped")
    assert_equal failed.fetch(:id), hold.rule_id
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_includes item.choices, "override_once"
  end

  test "a running blocking gate defers the approval until check re-entry" do
    gate = setup_rule("gate", "model")
    G.implementation = G::StandIn.new(rules: [ gate, @policy ])
    ctx = @scenario.context
    Gate.request_action(ctx, @action)
    assert_equal [ "rule_check" ], Job.where(task_id: @task.id).pluck(:kind)
    assert_empty Leverage::Holds.open_holds(@task)

    check = ::RuleCheck.find_by!(task_id: @task.id, rule_id: gate.fetch(:id))
    input = { "contract_version" => @task.contract_version, "action_kind" => @action.kind, "action_description" => @action.description }
    request = G::Request.new(workspace_id: @task.workspace_id, task_id: @task.id, project_id: @task.project_id,
      hook: "action.requested", round: @task.round, subject_kind: "action", subject_id: @action.id,
      requester_kind: "app", requester_id: nil, command_key: nil, inputs: input)
    G.implementation = G::StandIn.new(rules: [ gate, @policy ], actions: {
      @action.id => { request: request, checks: [ { id: check.id, rule_id: gate.fetch(:id), result: "passed" } ] }
    })
    trigger = G::Trigger.new(kind: :check_finished, rule_check_id: check.id)
    Leverage::CheckReentry.after(ctx, check, trigger)
    Leverage::CheckReentry.after(ctx, check, trigger)

    assert_equal 1, Job.where(task_id: @task.id, kind: "approval").count
  end

  test "only the check that stopped the action can override its stop" do
    failed = setup_rule("gate", "app", app_result: "failed")
    G.implementation = G::StandIn.new(rules: [ failed, @policy ])
    Gate.request_action(@scenario.context, @action)
    check = ::RuleCheck.find_by!(task_id: @task.id, rule_id: failed.fetch(:id))
    other = @scenario.rule_check(@task, rule: @scenario.rule(hook: "action.requested"), subject: @action, result: "failed")
    assert_equal :refused, override(other).outcome

    assert_equal :completed, override(check).outcome
    assert_equal "approved", @action.reload.state
    assert_empty Leverage::Holds.open_holds(@task)
    assert_empty Job.where(task_id: @task.id, kind: "approval")
  end

  private

  def override(check)
    params = { "id" => check.id, "reason" => "Sample override reason" }
    Leverage::Transitions.apply(Leverage::Transitions::Request.new(command: "override_check", workspace_id: @task.workspace_id,
      caller_kind: "owner", caller_id: @scenario.owner.id, key: SecureRandom.uuid,
      request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end

  def setup_rule(kind, checker, **options)
    rule = @scenario.rule(hook: "action.requested", kind: kind, checker: checker)
    { id: rule.id, version_id: @scenario.current_version(rule).id, hook: "action.requested", kind: kind, checker: checker,
      on_fail: "block", route: "owner", enabled: true, **options }
  end
end
