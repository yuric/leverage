# A change to tasks.state without an event for that task in the same
# transaction is rejected (PRD, Data model; C7, DB-6). Inserting a task
# counts as a change.
#
# Each events insert appends its task_id to a transaction-local setting.
# A setting changed inside a savepoint reverts when the savepoint rolls back
# and survives its release, which is the rule for "in the same
# transaction". (Comparing xmin does not work: rows written inside a
# savepoint carry a subtransaction id.) The check is a constraint trigger
# deferred to commit, so a command may change the state before it appends
# its event.
class AddTaskStateTrigger < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION leverage_note_evented_task() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.task_id IS NOT NULL THEN
          PERFORM set_config(
            'leverage.evented_tasks',
            coalesce(nullif(current_setting('leverage.evented_tasks', true), ''), ',') || NEW.task_id::text || ',',
            true
          );
        END IF;
        RETURN NULL;
      END;
      $$;

      CREATE TRIGGER events_note_evented_task
        AFTER INSERT ON events
        FOR EACH ROW EXECUTE FUNCTION leverage_note_evented_task();

      CREATE FUNCTION leverage_require_task_event() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF strpos(coalesce(current_setting('leverage.evented_tasks', true), ''), ',' || NEW.id::text || ',') = 0 THEN
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
      DROP TRIGGER events_note_evented_task ON events;
      DROP FUNCTION leverage_note_evented_task();
    SQL
  end
end
