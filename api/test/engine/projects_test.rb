require "test_helper"
require_relative "entries/jobs_support"

class ProjectsTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @project = scenario.project(budget: 5)
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new
  end

  test "a budget pause holds 450 open tasks in batches of 200 and opens one project item" do
    builder = own_seat
    task = scenario.task(state: "working", builder: builder, project: @project)
    open_ids = [ task.id ] + Array.new(449) { scenario.task(project: @project).id }
    closed_ids = %w[done cancelled].map { |state| scenario.task(state: state, project: @project).id }
    rule = pause_policy
    events, sizes = with_batch_sizes do
      events_written do
        assert_completed(seat_command(builder, "report_cost", { "id" => task.id, "tokens" => 50, "spend" => 5 }))
      end
    end

    cost, check, pause, *holds, item = events
    assert_equal %w[cost.reported check.finished project.paused inbox.opened], types([ cost, check, pause, item ])
    assert_equal cost.id, check.payload.fetch("subject_id")
    assert_equal [ "app", nil, check.id, cost.command_id ], pause.values_at(:actor_kind, :actor_id, :cause_id, :command_id)
    assert_equal [ 200, 200, 200 ], sizes
    expected = Task.where(id: open_ids).order(:created_at, :id).pluck(:id)
    assert_equal expected, holds.map(&:task_id)
    assert_equal [ [ "hold.opened", pause.id, "project_paused", rule.id ] ],
      holds.map { |event| [ event.type, event.cause_id, *event.payload.values_at("reason", "rule_id") ] }.uniq
    assert_empty Hold.where(task_id: closed_ids)
    assert_equal [ @project.id, nil, pause.id ], item.values_at(:project_id, :task_id, :cause_id)
    assert @project.reload.paused
    assert_nil task.reload.lease_due_at

    resumed, resume_sizes = with_batch_sizes do
      events_written { assert_completed(owner_command("change_budget", { "id" => @project.id, "budget" => 6 })) }
    end
    assert_equal [ 200, 200, 200 ], resume_sizes
    assert_equal [ "project.budget_changed", "project.resumed", *Array.new(450, "hold.closed"), "inbox.resolved" ], types(resumed)
    assert_equal expected, resumed[2, 450].map(&:task_id)
    assert_empty Hold.where(project_id: @project.id, closed_at: nil)
    refute @project.reload.paused
    assert task.reload.lease_due_at
  end

  test "lowering a running project's budget never pauses it" do
    @project.update!(spent: 3)
    events = events_written { assert_completed(owner_command("change_budget", { "id" => @project.id, "budget" => 2 })) }

    assert_equal %w[project.budget_changed], types(events)
    refute @project.reload.paused
  end

  test "a budget pause stays while still at budget and resumes on an empty budget" do
    spend_to_pause
    events = events_written { assert_completed(owner_command("change_budget", { "id" => @project.id, "budget" => 5 })) }

    assert_equal %w[project.budget_changed], types(events)
    assert @project.reload.paused

    events = events_written { assert_completed(owner_command("change_budget", { "id" => @project.id, "budget" => nil })) }

    assert_equal %w[project.budget_changed project.resumed hold.closed inbox.resolved], types(events)
    assert_equal "change_budget", events.last.payload.fetch("choice")
    refute @project.reload.paused
    assert_nil @project.budget
  end

  test "raising the budget of a project the owner paused keeps its holds" do
    task = scenario.task(project: @project)
    assert_completed(owner_command("pause_project", { "id" => @project.id }))
    events = events_written { assert_completed(owner_command("change_budget", { "id" => @project.id, "budget" => 7 })) }

    assert_equal %w[project.budget_changed], types(events)
    assert @project.reload.paused
    assert_equal "project_paused", open_hold(task).reason
    assert_empty InboxItem.where(about_id: @project.id)
  end

  test "the owner can resume at budget and the next cost report may pause it again" do
    builder, task = spend_to_pause
    events = events_written { assert_completed(owner_command("resume_project", { "id" => @project.id })) }

    assert_equal %w[project.resumed hold.closed inbox.resolved], types(events)
    assert_equal "resume_project", events.last.payload.fetch("choice")
    refute @project.reload.paused
    assert task.reload.lease_due_at

    assert_completed(seat_command(builder, "report_cost", { "id" => task.id, "tokens" => 1, "spend" => 0.1 }))
    assert @project.reload.paused
    assert_equal 1, InboxItem.where(about_id: @project.id, state: "open").count
  end

  test "moving into and out of a paused project changes the hold but leaves spend where reported" do
    builder = own_seat
    task = scenario.task(state: "working", builder: builder, project: @project)
    paused = scenario.project
    assert_completed(owner_command("pause_project", { "id" => paused.id }))
    assert_completed(seat_command(builder, "report_cost", { "id" => task.id, "tokens" => 5, "spend" => 1 }))

    moved = events_written { assert_completed(owner_command("change_task_project", { "id" => task.id, "project_id" => paused.id })) }

    assert_equal %w[task.changed hold.opened], types(moved)
    assert_equal moved.first.id, moved.last.cause_id
    assert_equal paused.id, open_hold(task).project_id
    assert_empty InboxItem.where(about_id: paused.id)

    moved = events_written { assert_completed(owner_command("change_task_project", { "id" => task.id, "project_id" => nil })) }

    assert_equal %w[task.changed hold.closed], types(moved)
    assert_nil moved.last.project_id
    assert_equal moved.first.id, moved.last.cause_id
    assert_nil open_hold(task)
    assert_equal [ 1, 0, 1 ], [ @project.reload.spent, paused.reload.spent, task.reload.spent ]
  end

  test "a move between paused projects always has a hold and can only be released by the destination" do
    builder = own_seat
    task = scenario.task(state: "working", builder: builder, project: @project)
    destination = scenario.project
    [ @project, destination ].each { |project| assert_completed(owner_command("pause_project", { "id" => project.id })) }

    moved = events_written do
      assert_completed(owner_command("change_task_project", { "id" => task.id, "project_id" => destination.id }))
    end
    assert_equal %w[task.changed hold.opened hold.closed], types(moved)
    assert_equal destination.id, open_hold(task).project_id
    assert_nil task.reload.resume_pending_since
    assert_nil task.lease_due_at

    assert_completed(owner_command("resume_project", { "id" => @project.id }))
    assert_equal destination.id, open_hold(task).project_id
    assert_completed(owner_command("resume_project", { "id" => destination.id }))
    assert_nil open_hold(task)
    assert task.reload.lease_due_at
  end

  test "joining a paused project only holds open tasks" do
    task = scenario.task(state: "done")
    assert_completed(owner_command("pause_project", { "id" => @project.id }))
    events = events_written { assert_completed(owner_command("change_task_project", { "id" => task.id, "project_id" => @project.id })) }

    assert_equal %w[task.changed], types(events)
    assert_nil open_hold(task)
  end

  test "project settings are scoped to the caller's workspace" do
    foreign = Scenario.new.project
    task = scenario.task(project: @project)

    assert_raises(Leverage::Transitions::NotFound) { owner_command("pause_project", { "id" => foreign.id }) }
    assert_raises(Leverage::Transitions::Invalid) do
      owner_command("change_task_project", { "id" => task.id, "project_id" => foreign.id })
    end
    assert_equal @project.id, task.reload.project_id
    refute foreign.reload.paused
  end

  test "editing the whole brief keeps matching rows, moves positions and records one version" do
    initial = [ entry("rule", "Use the sample."), entry("decision", "Use units."), entry("lesson", "Keep the label.") ]
    assert_completed(edit(initial))
    first, removed, last = brief_rows
    proposed = [ initial.last, initial.first, entry("lesson", "Sort the records.") ]
    events = events_written { assert_completed(edit(proposed)) }

    assert_equal [ last.id, first.id ], brief_rows.first(2).map(&:id)
    assert_equal [ 1, 2, 3 ], brief_rows.map(&:position)
    assert_equal proposed.map { |row| row.fetch("text") }, brief_rows.map(&:text)
    assert_equal %w[brief.changed brief.changed], types(events)
    assert_equal [ removed.id, brief_rows.last.id ], events.map(&:subject_id)
    assert_equal [ { "brief_version" => 2 } ], events.map(&:payload).uniq
    assert_equal [ "owner", scenario.owner.id ], brief_rows.last.values_at(:author_kind, :author_id)
    assert_empty events_written { assert_completed(edit(proposed)) }
    assert_equal 2, @project.reload.brief_version
  end

  test "reordering the same entries changes the brief version and keeps the rows" do
    initial = [ entry("rule", "Use the sample."), entry("lesson", "Keep the label.") ]
    assert_completed(edit(initial))
    ids = brief_rows.map(&:id)
    events = events_written { assert_completed(edit(initial.reverse)) }

    assert_equal ids.reverse, brief_rows.map(&:id)
    assert_equal 2, @project.reload.brief_version
    assert_equal [ { "brief_version" => 2 } ], events.map(&:payload).uniq
  end

  test "a priority change moves the task ahead of an earlier task when a builder claims" do
    builder = own_seat
    first = scenario.task(state: "ready", project: @project)
    second = scenario.task(state: "ready", project: @project)
    second.update!(budget_cap: 2)
    events = events_written do
      assert_completed(owner_command("change_task_priority", { "id" => second.id, "priority" => "high" }))
    end

    assert_equal({ "priority" => "high", "project_id" => @project.id, "budget_cap" => 2 }, events.sole.payload)
    claim = assert_completed(seat_command(builder, "claim"))
    assert_equal second.id, claim.result.fetch("task_id")
    assert_equal "ready", first.reload.state
  end

  private

  def spend_to_pause
    builder = own_seat
    task = scenario.task(state: "working", builder: builder, project: @project)
    pause_policy
    assert_completed(seat_command(builder, "report_cost", { "id" => task.id, "tokens" => 5, "spend" => 5 }))
    assert @project.reload.paused
    [ builder, task ]
  end

  def pause_policy
    rule = scenario.rule(hook: "cost.reported", kind: "policy", checker: "app", checker_function: "pause_project_at_budget")
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(rules: [
      { id: rule.id, version_id: scenario.current_version(rule).id, version: 1, hook: "cost.reported", kind: "policy",
        checker: "app", enabled: true, effect: "project_paused" }
    ])
    rule
  end

  def with_batch_sizes
    sizes = []
    subscriber = lambda do |*_, data|
      next unless data[:sql].match?(/SELECT "tasks"\.\* FROM "tasks".*ORDER BY.*LIMIT/)

      sizes.concat(data[:binds].select { |bind| bind.name == "LIMIT" }.map(&:value_for_database))
    end
    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    [ result, sizes ]
  end

  def entry(kind, text) = { "kind" => kind, "text" => text }
  def edit(entries) = owner_command("edit_brief", { "id" => @project.id, "entries" => entries })
  def brief_rows = BriefEntry.where(project_id: @project.id).order(:position).to_a
end
