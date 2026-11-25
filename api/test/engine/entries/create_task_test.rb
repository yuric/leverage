require "test_helper"
require_relative "gated_flow_support"

class CreateTaskTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup do
    use_scenario
    @seat = scenario.seat(role: "reviewer")
    @body = contract_body.slice("title", "details", "criteria")
  end

  test "the creator is the actor in Backlog, on the completed contract and in Ready" do
    events = events_written do
      answer = assert_completed(seat_command(@seat, "add_task", @body))
      task = Task.find(answer.result.fetch("task_id"))
      assert_equal({ "task_id" => task.id, "state" => "ready" }, answer.result)
    end
    assert_equal %w[task.created task.contract_changed task.ready], events.map(&:type)
    assert events.all? { |event| event.actor_kind == "seat" && event.actor_id == @seat.id }
  end

  test "Create off refuses the command without creating a task" do
    @seat.update!(may_create: false)
    assert_no_difference("Task.count") { assert_refused "forbidden", seat_command(@seat, "add_task", @body) }
  end

  test "failed app check leaves a contract for the owner to complete" do
    rule = scenario.rule(hook: "task.before_ready", checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => 4 })
    answer = assert_completed(seat_command(@seat, "add_task", @body))
    task = Task.find(answer.result.fetch("task_id"))
    assert_equal({ "task_id" => task.id, "state" => "backlog" }, answer.result)
    assert_equal [ "contract_incomplete" ], open_holds(task).map(&:reason)
    item = open_items(task).sole
    assert_equal [ "agent_task_incomplete", { "seat_id" => @seat.id } ], [ item.kind, item.facts ]
    assert_completed(owner_command("disable_rule", { "id" => rule.id }))
    assert_completed(owner_command("complete_contract", contract_body.merge("id" => task.id)))
    assert_equal "resolved", item.reload.state
    assert_equal "ready", task.reload.state
  end

  test "a task added in a paused project is held" do
    project = scenario.project(paused: true)
    answer = assert_completed(seat_command(@seat, "add_task", @body.merge("project_id" => project.id)))
    task = Task.find(answer.result.fetch("task_id"))
    assert_equal project.id, task.project_id
    assert_includes open_holds(task).map(&:reason), "project_paused"
  end

  %w[task review job].each do |kind|
    test "a creator holding a #{kind} inherits its project and cannot name another" do
      project = scenario.project
      case kind
      when "task" then scenario.task(state: "working", project: project, builder: @seat)
      when "review" then scenario.review(scenario.task(state: "in_review", project: project), reviewer: @seat)
      when "job" then scenario.job(kind: "contract_draft", task: scenario.task(project: project), state: "claimed", seat: @seat)
      end
      answer = assert_completed(seat_command(@seat, "add_task", @body.merge("project_id" => nil)))
      assert_equal project.id, Task.find(answer.result.fetch("task_id")).project_id
      other = scenario.project(name: "Another project")
      assert_no_difference("Task.count") do
        assert_raises(T::Invalid) { seat_command(@seat, "add_task", @body.merge("project_id" => other.id)) }
      end
    end
  end
end
