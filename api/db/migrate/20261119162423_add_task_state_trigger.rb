# A change to tasks.state without an event for that task in the same
# transaction is rejected (PRD, Data model; C7, DB-6). Inserting a task
# counts as a change.
#
# The check looks for an events row of the same task and workspace whose
# xact_id, set by default to pg_current_xact_id(), is this transaction's.
# pg_current_xact_id() is the top-level transaction id inside savepoints
# too, and an event inside a savepoint that rolled back is gone, which is
# the rule for "in the same transaction". Only an event row satisfies it:
# no setting a caller can write stands in for one. (Comparing xmin does not
# work: rows written inside a savepoint carry a subtransaction id.) The
# check is a constraint trigger deferred to commit, so a command may change
# the state before it appends its event.
class AddTaskStateTrigger < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION leverage_require_task_event() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM events
          WHERE task_id = NEW.id AND workspace_id = NEW.workspace_id AND xact_id = pg_current_xact_id()
        ) THEN
          RAISE EXCEPTION 'tasks.state of task % changed without an event for that task in the same transaction', NEW.id
            USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NULL;
      END;
      $$;

      CREATE CONSTRAINT TRIGGER tasks_insert_requires_event
        AFTER INSERT ON tasks
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION leverage_require_task_event();

      CREATE CONSTRAINT TRIGGER tasks_state_change_requires_event
        AFTER UPDATE OF state ON tasks
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW
        WHEN (OLD.state IS DISTINCT FROM NEW.state)
        EXECUTE FUNCTION leverage_require_task_event();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER tasks_state_change_requires_event ON tasks;
      DROP TRIGGER tasks_insert_requires_event ON tasks;
      DROP FUNCTION leverage_require_task_event();
    SQL
  end
end
