require "test_helper"

# Leverage::EventLog.append, the only inserter of events (PRD L215-L222;
# milestone 2 plan §2.1): seq from the workspace's counter, the payload
# checked against its schema, the subject against its type, and the step
# tracker told in the same call.
class EventLogTest < ActiveSupport::TestCase
  # The seat is made before the context: a context holds the workspace row
  # it locked, so no other writer may append while a test holds it.
  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat
    @ctx = @scenario.context
  end

  def append(type = "task.created", **fields)
    Leverage::EventLog.append(@ctx, type: type, **fields)
  end

  def with_task
    task = Task.create!(workspace_id: @scenario.workspace_id, state: "backlog")
    [ task, append(task: task, schema_version: 1, payload: { state: "backlog", added_action_ids: [] }) ]
  end

  test "seq comes from the workspace's counter, which each append moves on" do
    before = @scenario.workspace.reload.last_seq
    _task, first = with_task
    second = append("project.created", project_id: Project.create!(workspace_id: @scenario.workspace_id).id,
      payload: { imaginarium: false })

    assert_equal [ before + 1, before + 2 ], [ first.seq, second.seq ]
    assert_equal before + 2, @scenario.workspace.reload.last_seq
    assert_equal before + 2, @ctx.workspace.last_seq
  end

  test "an event takes the context's at, the newest schema version, and the task's round and project" do
    task = Task.create!(workspace_id: @scenario.workspace_id, state: "backlog")
    payload = { "state" => "backlog", "added_action_ids" => [], "imaginarium_entry" => "pocket-to-do", "added_criterion_ids" => [] }
    event = append(task: task, payload: payload)

    assert_equal [ @ctx.at, @ctx.at, 2, 0, nil, task.id ],
      [ event.at, event.effective_at, event.schema_version, event.round, event.project_id, event.task_id ]
    assert_equal payload, event.reload.payload
  end

  test "a timer's event carries its due time as effective_at" do
    task, = with_task
    due = @ctx.at - 30
    event = append("task.promoted", task: task, payload: {}, effective_at: due, actor_kind: "app", actor_id: nil)

    assert_equal [ due, @ctx.at ], [ event.effective_at, event.at ]
  end

  test "a payload its schema refuses is not inserted" do
    task, = with_task
    count = Event.count
    error = assert_raises(Leverage::EventLog::InvalidEvent) do
      append("task.created", task: task, schema_version: 1, payload: { state: "made_up_state", added_action_ids: [] })
    end
    assert_match(/task\.created/, error.message)
    assert_equal count, Event.count
  end

  test "an unregistered type is refused" do
    assert_raises(Leverage::EventLog::InvalidEvent) { append("task.made_up", payload: {}) }
  end

  test "a subject the type does not allow is refused" do
    task, = with_task
    seat = @seat

    assert_raises(Leverage::EventLog::InvalidEvent) { append("task.promoted", task: task, subject: seat, payload: {}) }
    assert_raises(Leverage::EventLog::InvalidEvent) { append("seat.connected", payload: {}) }
    event = append("seat.connected", subject: seat, payload: {})
    assert_equal [ "seat", seat.id, nil, nil ], [ event.subject_kind, event.subject_id, event.task_id, event.round ]
  end

  test "the step tracker is told of every event, in the same call" do
    told = []
    original = Leverage::Steps.method(:on_event)
    Leverage::Steps.define_singleton_method(:on_event) do |ctx, event|
      told << [ ctx, event.id ]
      original.call(ctx, event)
    end
    _task, event = with_task

    assert_equal [ [ @ctx, event.id ] ], told
  ensure
    Leverage::Steps.define_singleton_method(:on_event, original) if original
  end

  test "the context keeps the events it wrote, in order" do
    task, first = with_task
    second = append("task.promoted", task: task, payload: {})

    assert_equal [ first.id, second.id ], @ctx.events.map(&:id)
  end
end

# Reads::Snapshot (MA-20): the rows a read returns and the as_of_seq it
# reports are one moment of the log, even while a writer commits.
class EventLogSnapshotTest < CommittingTestCase
  test "a snapshot reports the log position its rows were read at" do
    scenario.task
    seen = Leverage::Reads::Snapshot.call(scenario.workspace_id) do |as_of_seq|
      before = Event.where(workspace_id: scenario.workspace_id).count
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { scenario.task }
      end.join
      [ as_of_seq, before, Event.where(workspace_id: scenario.workspace_id).count ]
    end

    as_of_seq, before, after = seen
    assert_equal before, after, "the second read in the snapshot saw a later commit"
    assert_equal Event.where(workspace_id: scenario.workspace_id).where("seq <= ?", as_of_seq).count, before
    assert_operator scenario.workspace.reload.last_seq, :>, as_of_seq
  end

  test "a snapshot cannot write" do
    assert_raises(ActiveRecord::StatementInvalid) do
      Leverage::Reads::Snapshot.call(scenario.workspace_id) { |_| scenario.task }
    end
  end
end
