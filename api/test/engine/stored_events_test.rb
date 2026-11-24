require "test_helper"

# DB-52: the task state "imaginarium" was renamed "ideas". The event log is
# append-only, so a task.created written before the rename still says
# "imaginarium". Every reader of a stored task.created reads it as "ideas":
# the step tracker, the replay behind leverage:verify_log, and the log audit.
class StoredEventsTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
  end

  # A task in Ideas whose task.created is written the old way. EventLog would
  # refuse that payload, as it checks every new event against the schema, so
  # the event is stored directly, as a log written before the rename holds it.
  def old_spelling_task
    ctx = @scenario.context
    task = Task.create!(workspace_id: @scenario.workspace_id, title: "A made-up task", goal: "A made-up goal.",
      work_reference: "~/work/made-up", priority: "normal", state: "ideas")
    event = Event.create!(workspace_id: @scenario.workspace_id, seq: ctx.workspace.last_seq + 1, at: ctx.at,
      effective_at: ctx.at, type: "task.created", schema_version: 1, actor_kind: "owner", actor_id: @owner.id,
      task_id: task.id, round: 0, payload: { "state" => "imaginarium", "added_action_ids" => [] })
    ctx.workspace.update_columns(last_seq: event.seq)
    Leverage::Steps.on_event(ctx, event)
    task
  end

  test "the schemas refuse the old spelling in a new event" do
    errors = Leverage::Contract.validate_payload("task.created", 1, { "state" => "imaginarium", "added_action_ids" => [] })
    assert_not_empty errors
  end

  test "a stored task.created that says imaginarium opens the idea step" do
    task = old_spelling_task
    assert_equal [ "idea" ], TaskStep.where(task_id: task.id, closed_at: nil).pluck(:kind)
  end

  test "a log with a stored imaginarium task.created replays with the task in ideas" do
    task = old_spelling_task
    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
    assert_equal "ideas", Leverage::Replay.project(@scenario.workspace_id).fetch(:tasks).fetch(task.id).fetch("state")
  end

  test "the log audit folds a stored imaginarium task.created into ideas" do
    task = old_spelling_task
    event = Event.find_by!(task_id: task.id, type: "task.created")
    assert_equal "ideas", Leverage::LogAudit.observe(nil, [ event ])
  end

  test "the mapping turns the old spelling into the new one and passes everything else through" do
    assert_equal "ideas", Leverage::StoredEvents.task_state("imaginarium")
    assert_equal "ideas", Leverage::StoredEvents.task_state("ideas")
    assert_equal "backlog", Leverage::StoredEvents.task_state("backlog")
    assert_nil Leverage::StoredEvents.task_state(nil)
  end

  test "replaying a task.created with no state still raises KeyError" do
    ctx = @scenario.context
    task = Task.create!(workspace_id: @scenario.workspace_id, title: "A made-up task", goal: "A made-up goal.",
      work_reference: "~/work/made-up", priority: "normal", state: "ideas")
    event = Event.create!(workspace_id: @scenario.workspace_id, seq: ctx.workspace.last_seq + 1, at: ctx.at,
      effective_at: ctx.at, type: "task.created", schema_version: 1, actor_kind: "owner", actor_id: @owner.id,
      task_id: task.id, round: 0, payload: {})
    ctx.workspace.update_columns(last_seq: event.seq)
    assert_raises(KeyError) { Leverage::Replay.project(@scenario.workspace_id) }
  end
end
