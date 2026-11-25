require "test_helper"
require_relative "entries/jobs_support"

# The log audit on tasks a seat added (UX-11, UX-14, UX-16): what it reads
# for a seat's add_task and for the workspace cap's Needs you item, and,
# for each, the nearest log it must still report. Every value is made up.
class LogAuditAgentTasksTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @seat = scenario.seat(role: "reviewer")
    @body = contract_body.slice("title", "details", "criteria")
    @start = scenario.workspace.reload.last_seq
  end

  def add(seat = @seat, body = @body) = seat_command(seat, "add_task", body)

  def audit(after = @start) = Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)

  def app_gate(minimum)
    scenario.rule(hook: "task.before_ready", checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => minimum })
  end

  # The events the seat's add_task wrote, in seq order.
  def added
    key = new_key
    answer = assert_completed(seat_command(@seat, "add_task", @body, key: key))
    [ Task.find(answer.result.fetch("task_id")), Event.where(workspace_id: scenario.workspace_id, command_id: key).order(:seq).to_a ]
  end

  def copy(event, **changes) = event.dup.tap { |forged| forged.assign_attributes(**changes) }

  # --- the seat's add_task: add_task, then complete_contract ---------------------

  test "a seat's add_task that passes an enabled app gate to Ready passes" do
    rule = app_gate(1)
    start = scenario.workspace.reload.last_seq
    task, events = added

    assert_equal %w[task.created check.finished task.contract_changed task.ready], events.map(&:type)
    assert_equal [ "ready", [ "task.before_ready", "passed", rule.id ] ],
      [ task.state, events.second.payload.values_at("hook", "result", "rule_id") ]
    assert_empty audit(start)
  end

  test "a seat's add_task past an enabled gate with no check is found" do
    rule = app_gate(1)
    start = scenario.workspace.reload.last_seq
    added
    RuleCheckAttempt.where(workspace_id: scenario.workspace_id).delete_all
    RuleCheck.where(workspace_id: scenario.workspace_id).delete_all

    found = audit(start)
    assert(found.any? { |line| line.include?("task.ready past the blocking gate of rule #{rule.id}") }, found.inspect)
  end

  test "only a seat's task created in Backlog reads as add_task followed by complete_contract" do
    _, events = added
    created = events.first
    assert_equal %w[task.created task.contract_changed task.ready], events.map(&:type)
    assert_equal [ "seat", "backlog" ], [ created.actor_kind, created.payload["state"] ]
    assert_empty Leverage::LogAudit.named("the add", [ "add_task" ], events, {})

    by_owner = [ copy(created, actor_kind: "owner", actor_id: scenario.owner.id), *events.drop(1) ]
    assert_match(/add_task .*task\.ready/, Leverage::LogAudit.named("the add", [ "add_task" ], by_owner, {}).sole)

    in_ideas = [ copy(created, payload: created.payload.merge("state" => "ideas")), *events.drop(1) ]
    assert_match(/add_task /, Leverage::LogAudit.named("the add", [ "add_task" ], in_ideas, {}).sole)

    # An item on another task is a side event add_task's own row would
    # take; the two halves are read only for one task.
    other = scenario.task(state: "working")
    item = copy(created, type: "inbox.opened", task_id: other.id, subject_kind: "inbox_item", subject_id: SecureRandom.uuid,
      actor_kind: "app", actor_id: nil, payload: { "kind" => "limit_with_no_reset_time" })
    assert_empty Leverage::LogAudit.match("add_task", [ created, item ], { other.id => "working" })
    two_tasks = [ created, item, *events.drop(1) ]
    assert_match(/add_task /, Leverage::LogAudit.named("the add", [ "add_task" ], two_tasks, { other.id => "working" }).sole)

    assert_match(/complete_contract /, Leverage::LogAudit.named("the add", [ "complete_contract" ], events, {}).sole)
  end

  # --- the first step of a task a seat added ------------------------------------

  test "the first step of a seat's task may open at a later event of its own command only" do
    app_gate(4)
    start = scenario.workspace.reload.last_seq
    task, events = added
    created = events.first
    first = TaskStep.where(task_id: task.id).order(:opened_at).first
    opener = Event.find(first.opening_event_id)

    assert_equal "backlog", task.state
    refute_equal created.id, opener.id
    assert_equal [ created.command_id, created.at, created.effective_at ], [ opener.command_id, opener.at, opener.effective_at ]
    assert_empty audit(start)

    # An event of the same command that does not open that step.
    changed = events.find { |event| event.type == "task.contract_changed" }
    refute Leverage::Steps.opens?(first.kind, changed.type)
    first.update_columns(opening_event_id: changed.id)
    assert_includes audit(start), "steps of task #{task.id}: the first step (#{first.kind}) does not open at task.created"

    # The same kind of event, written by the owner's later command.
    assert_completed(owner_command("hold", { "id" => task.id, "note" => "A made-up note." }))
    later = Event.where(task_id: task.id, type: opener.type).where("seq > ?", opener.seq).order(:seq).first
    assert later, "the owner's hold must write #{opener.type}"
    first.update_columns(opening_event_id: later.id)
    assert_includes audit(start), "steps of task #{task.id}: the first step (#{first.kind}) does not open at task.created"
  end

  test "the first step of the owner's task opens at task.created itself" do
    project = scenario.project
    assert_completed(owner_command("pause_project", { "id" => project.id }))
    start = scenario.workspace.reload.last_seq
    key = new_key
    answer = assert_completed(owner_command("add_task", { "title" => "An owner's task", "project_id" => project.id }, key: key))
    task = Task.find(answer.result.fetch("task_id"))
    created, held = Event.where(workspace_id: scenario.workspace_id, command_id: key, task_id: task.id).order(:seq).first(2)
    assert_equal [ "task.created", "hold.opened" ], [ created.type, held.type ]
    first = TaskStep.where(task_id: task.id).order(:opened_at).first
    assert_equal created.id, first.opening_event_id
    assert_empty audit(start)

    # The same shape as the seat's: a later event of the same command, at
    # the same time, that opens the step's kind. Only the actor differs.
    assert Leverage::Steps.opens?("wait_owner", held.type)
    TaskStep.where(task_id: task.id).where.not(id: first.id).delete_all
    first.update_columns(kind: "wait_owner", opening_event_id: held.id)
    assert_includes audit(start), "steps of task #{task.id}: the first step (wait_owner) does not open at task.created"
  end

  # --- the workspace cap's Needs you item (agent_tasks_at_limit) -----------------

  def fill_to_cap
    seats = [ @seat, scenario.seat, scenario.seat ]
    @start = scenario.workspace.reload.last_seq
    tasks = Array.new(Leverage::AgentTasks::CAP) { |index| assert_completed(add(seats[index % 3])).result.fetch("task_id") }
    assert_refused("add_task_limit", add)
    [ tasks, InboxItem.where(workspace_id: scenario.workspace_id, kind: "agent_tasks_at_limit").sole ]
  end

  test "the cap's item passes the audit when a refused add opens it and when a cancel closes it" do
    tasks, item = fill_to_cap
    opened = Event.find_by!(workspace_id: scenario.workspace_id, type: "inbox.opened", subject_id: item.id)
    assert_equal [ "open", "add_task", "refused" ],
      [ item.state, *Command.find_by!(workspace_id: scenario.workspace_id, key: opened.command_id).values_at(:command, :outcome) ]
    assert_empty audit

    assert_completed(owner_command("cancel", { "id" => tasks.first }))
    assert_equal "resolved", item.reload.state
    assert_empty audit
  end

  test "the sweep closes the cap's item once the workspace is under the cap, and the audit reads its timer" do
    tasks, item = fill_to_cap
    now = scenario.database_now
    assert_predicate Leverage::Timers.apply_workspace(scenario.workspace_id, "reviewer_eligibility", at: now), :completed?
    assert_equal "open", item.reload.state, "at the cap the sweep leaves the item open"

    # No command leaves the cap without the terminal event that closes the
    # item itself, so the open task count is lowered on the row alone.
    Task.where(id: tasks.first).update_all(state: "cancelled")
    assert_predicate Leverage::Timers.apply_workspace(scenario.workspace_id, "reviewer_eligibility", at: now), :completed?

    assert_equal [ "resolved", "app" ], item.reload.values_at(:state, :resolved_by_kind)
    closed = Event.where(workspace_id: scenario.workspace_id, type: "inbox.resolved", subject_id: item.id).sole
    assert_equal [ nil, "app" ], [ closed.command_id, closed.actor_kind ]
    assert_empty audit
  end

  test "the cap's item opened with no key is no timer's: only a refused add opens it" do
    item = InboxItem.create!(workspace_id: scenario.workspace_id, kind: "agent_tasks_at_limit", about_kind: "workspace",
      about_id: scenario.workspace_id, facts: {}, choices: [], opened_at: scenario.database_now)
    opened = scenario.append("inbox.opened", subject: item, payload: { kind: item.kind })
    assert_equal [ nil, "app" ], [ opened.command_id, opened.actor_kind ]

    assert_match(/events with no command \(seq #{opened.seq}, inbox\.opened\): no command no timer writes them/, audit.sole)
  end
end
