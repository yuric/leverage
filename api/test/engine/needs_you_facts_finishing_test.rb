require "test_helper"

class NeedsYouFactsFinishingTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
  end

  test "passing approval to the owner identifies the action" do
    task = finishing_task("requested")
    action = Action.find_by!(task_id: task.id)
    Leverage::Finishing.open_owner_approval(owner_context, action, check: nil, cause: nil)

    assert_equal({ "action_id" => action.id }, inbox_facts(task, "approval"))
    assert_equal action.id, Hold.find_by!(task_id: task.id, reason: "owner_approval").action_id
  end

  test "stopping an action records whether the builder announced a start" do
    task = finishing_task("started")
    action = Action.find_by!(task_id: task.id)
    ctx = owner_context
    Leverage::Actions.stop(ctx, action, by: ctx.actor)

    assert_equal({ "action_id" => action.id, "rule_check_id" => nil, "any_action_started" => true },
      inbox_facts(task, "stopped_action"))
    assert_equal action.id, Hold.find_by!(task_id: task.id, reason: "action_stopped").action_id
  end

  test "losing the builder identifies each open approved action and the first approval" do
    task = finishing_task("started", "approved")
    actions = Action.where(task_id: task.id).order(:position)
    first = actions.first
    Leverage::Finishing.lose_builder(owner_context, task, cause: nil)

    assert_equal({ "action_ids" => actions.ids, "approved_by_kind" => first.approved_by_kind,
      "approved_by_id" => first.approved_by_id, "builder_announced_start" => true },
      inbox_facts(task, "unconfirmed_action"))
  end

  private

  def finishing_task(*states)
    @scenario.finishing_task(builder: @builder,
      actions: states.map { |state| { kind: "send", description: "Send the example.", state: state } })
  end

  def owner_context
    request = Leverage::Transitions::Request.new(command: "test", workspace_id: @scenario.workspace_id,
      caller_kind: "owner", caller_id: @scenario.owner.id, key: SecureRandom.uuid, request_hash: nil, params: {})
    @scenario.context(request: request)
  end

  def inbox_facts(task, kind)
    inbox = Leverage::Reads::Inbox.call(task.workspace_id).fetch(:items).find { |item| item.fetch(:kind) == kind }
    inbox&.fetch(:facts)
  end
end
