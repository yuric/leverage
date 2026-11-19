require "test_helper"
require_relative "rows"

# A change to tasks.state without an event for that task in the same
# transaction is rejected by a trigger (PRD, Data model; C7, DB-6). Inserts
# count as changes. The trigger is deferred to commit; inside a test's
# transaction, SET CONSTRAINTS ALL IMMEDIATE fires it.
class StateTriggerTest < ActiveSupport::TestCase
  include DbRows

  def fire
    db.execute("SET CONSTRAINTS ALL IMMEDIATE")
  end

  def bare_task
    insert("tasks", workspace_id: workspace, state: "backlog")
  end

  test "inserting a task without an event for it is rejected" do
    error = assert_rejected do
      bare_task
      fire
    end
    assert_match(/without an event/, error.message)
  end

  test "inserting a task with an event for it passes" do
    assert_accepted do
      task_id = bare_task
      event(task_id: task_id)
      fire
    end
  end

  test "an event for another task does not count" do
    assert_rejected do
      bare_task
      event(task_id: task)
      fire
    end
  end

  # Only an event row of this transaction counts: no setting a caller can
  # write stands in for one.
  test "a transaction-local setting written by hand does not count" do
    assert_rejected do
      task_id = bare_task
      sql("SELECT set_config('leverage.evented_tasks', $1, true)", ",#{task_id},")
      fire
    end
  end

  test "an event for the task in another workspace does not count" do
    other = insert("workspaces", {})
    assert_rejected do
      task_id = bare_task
      event(task_id: task_id, workspace_id: other)
      fire
    end
  end

  test "an event inside a released savepoint counts" do
    assert_accepted do
      task_id = bare_task
      db.transaction(requires_new: true) { event(task_id: task_id) }
      fire
    end
  end

  test "an event inside a savepoint that was rolled back does not count" do
    assert_rejected do
      task_id = bare_task
      db.transaction(requires_new: true) do
        event(task_id: task_id)
        raise ActiveRecord::Rollback
      end
      fire
    end
  end

  test "a test that changes a state with no event fails at teardown, with no assertion of its own" do
    probe = Class.new(ActiveSupport::TestCase) do
      include DbRows
      def self.name = "StateTriggerTeardownProbe"
      define_method(:test_inserts_a_task_with_no_event) do
        insert("tasks", workspace_id: workspace, state: "backlog")
      end
    end
    Minitest::Runnable.runnables.delete(probe)
    result = probe.new("test_inserts_a_task_with_no_event").run
    refute result.passed?, "the probe test passed although it added a task with no event"
    assert_match(/without an event/, result.failures.map(&:message).join("\n"))
  end
end

# Changes to a task that an earlier, committed transaction created. These
# need real commits, so they run outside the transactional fixtures; the
# rows they commit stay, because events cannot be deleted.
class StateTriggerAcrossTransactionsTest < ActiveSupport::TestCase
  include DbRows
  self.use_transactional_tests = false

  setup do
    db.transaction { @task_id = task }
  end

  def state
    sql("SELECT state FROM tasks WHERE id = $1", @task_id).rows.first.first
  end

  def change_state(to)
    sql("UPDATE tasks SET state = $1 WHERE id = $2", to, @task_id)
  end

  def assert_commit_rejected(&block)
    error = assert_raises(ActiveRecord::StatementInvalid) { db.transaction(&block) }
    assert_match(/without an event/, error.message)
    assert_equal "backlog", state
  end

  test "an event from an earlier transaction does not count" do
    assert_commit_rejected { change_state("ready") }
  end

  test "an event for another task does not count" do
    assert_commit_rejected do
      event(task_id: task)
      change_state("ready")
    end
  end

  test "an event for the task in the same transaction lets the change commit" do
    db.transaction do
      event(task_id: @task_id, type: "task.ready")
      change_state("ready")
    end
    assert_equal "ready", state
  end

  test "an event in a released savepoint lets the change commit" do
    db.transaction do
      change_state("ready")
      db.transaction(requires_new: true) { event(task_id: @task_id, type: "task.ready") }
    end
    assert_equal "ready", state
  end

  test "an event in a savepoint rolled back does not count" do
    assert_commit_rejected do
      change_state("ready")
      db.transaction(requires_new: true) do
        event(task_id: @task_id, type: "task.ready")
        raise ActiveRecord::Rollback
      end
    end
  end

  test "an update that leaves the state as it was needs no event" do
    db.transaction { sql("UPDATE tasks SET state = state, priority = 'high' WHERE id = $1", @task_id) }
    assert_equal "high", sql("SELECT priority FROM tasks WHERE id = $1", @task_id).rows.first.first
  end
end
