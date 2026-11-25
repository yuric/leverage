require "test_helper"
require_relative "entries/jobs_support"

class AgentTasksTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @seat = scenario.seat
    @body = { "title" => "A follow-up", "criteria" => [ { "kind" => "review", "text" => "The reviewer agrees." } ] }
  end

  def add(seat = @seat) = seat_command(seat, "add_task", @body)

  test "the twenty-first task in a rolling hour is refused for this seat" do
    20.times { assert_completed(add) }
    answer = assert_refused("add_task_limit", add)
    assert_match(/20/, answer.refusal.reason)
    first = Event.where(workspace_id: scenario.workspace_id, type: "task.created", actor_id: @seat.id).minimum(:at)
    assert Leverage::AgentTasks.limit(@seat, nil, at: first + 1.hour - 1.second)
    assert_nil Leverage::AgentTasks.limit(@seat, nil, at: first + 1.hour)
    assert_completed(add(scenario.seat))
  end

  test "a second seat cannot extend a chain while holding or after submitting the task" do
    scenario.task(state: "working", builder: @seat)
    child = assert_completed(add).result.fetch("task_id")
    second = scenario.seat
    assert_equal child, assert_completed(seat_command(second, "claim")).result.dig("task", "id")
    assert_refused("add_task_limit", add(second))
    task = Task.find(child)
    assert_completed(seat_command(second, "acknowledge_briefing", { "id" => child,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: second) }))
    assert_completed(seat_command(second, "submit", { "id" => child, "handoff_note" => "Complete.", "work_reference" => nil }))
    assert_refused("add_task_limit", add(second))
  end

  test "the workspace cap opens one item until an open agent task ends" do
    seats = [ @seat, scenario.seat, scenario.seat ]
    tasks = Array.new(50) { |index| assert_completed(add(seats[index % 3])).result.fetch("task_id") }
    2.times do
      answer = assert_refused("add_task_limit", add)
      assert_match(/50/, answer.refusal.reason)
    end
    item = InboxItem.where(workspace_id: scenario.workspace_id, kind: "agent_tasks_at_limit").sole
    assert_equal [ "workspace", scenario.workspace_id, "open" ], [ item.about_kind, item.about_id, item.state ]
    assert_completed(owner_command("cancel", { "id" => tasks.first }))
    assert_equal "resolved", item.reload.state
    assert_completed(add)
  end
end
