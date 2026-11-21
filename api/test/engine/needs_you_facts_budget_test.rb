require "test_helper"
require_relative "entries/jobs_support"

# The two budget Needs you items opened by a cost report (WP7, trace 21).
class NeedsYouFactsBudgetTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @builder = scenario.seat(role: "builder")
  end

  test "the task budget item names the task and its hold and has empty facts" do
    task = scenario.task(state: "working", builder: @builder)
    task.update!(budget_cap: 2)

    events = report(task, effect: "task_held")

    hold = Hold.where(task_id: task.id, closed_at: nil).sole
    assert_equal "budget", hold.reason
    item = open_item
    assert_equal [ "task_budget_reached", "task", task.id, hold.id ],
      item.values_at(:kind, :about_kind, :about_id, :hold_id)
    assert_empty item.facts
    assert_equal choices_for(item.kind), item.choices
    cause = events.find { |event| event.type == "hold.opened" && event.subject_id == hold.id }
    opened = events.select { |event| event.type == "inbox.opened" }.sole
    assert_equal [ item.id, task.id, "app", nil, cause.id ],
      opened.values_at(:subject_id, :task_id, :actor_kind, :actor_id, :cause_id)
  end

  test "the project budget opens one item for the project with no hold id and empty facts" do
    project = scenario.project(budget: 2)
    task = scenario.task(state: "working", builder: @builder, project: project)
    other = scenario.task(state: "ready", project: project)

    events = report(task, effect: "project_paused")

    assert_equal [ task.id, other.id ].sort,
      Hold.where(project_id: project.id, reason: "project_paused", closed_at: nil).pluck(:task_id).sort
    item = open_item
    assert_equal [ "project_budget_reached", "project", project.id, nil ],
      item.values_at(:kind, :about_kind, :about_id, :hold_id)
    assert_empty item.facts
    assert_equal choices_for(item.kind), item.choices
    cause = events.select { |event| event.type == "project.paused" }.sole
    opened = events.select { |event| event.type == "inbox.opened" }.sole
    assert_equal [ item.id, project.id, nil, "app", nil, cause.id ],
      opened.values_at(:subject_id, :project_id, :task_id, :actor_kind, :actor_id, :cause_id)
  end

  private

  def report(task, effect:)
    rule = scenario.rule(key: "project_budget_pause", origin: "shipped")
    version = scenario.current_version(rule)
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(rules: [
      { id: rule.id, version_id: version.id, version: version.version, hook: version.hook, kind: version.kind,
        checker: version.checker, enabled: rule.enabled, scope: "covers", effect: effect }
    ])

    events_written do
      outcome = nil
      assert_nothing_raised do
        outcome = seat_command(@builder, "report_cost", { "id" => task.id, "tokens" => 80, "spend" => 2 })
      end
      assert_completed(outcome)
    end
  end

  def open_item = InboxItem.where(workspace_id: scenario.workspace_id, state: "open").sole

  def choices_for(kind)
    row = Leverage::Contract.needs_you.fetch("items").find { |item| item.fetch("item") == kind }
    row.fetch("choices").map { |choice| choice.fetch("choice") }
  end
end
