# DB-52: the task state "imaginarium" is renamed "ideas". Stored tasks move
# to the new name. The state's name changes, not the task's place in its
# lifecycle, so no event is written, and the trigger that refuses a state
# change with no event in the same transaction is off for this one UPDATE.
# The event log is append-only and is not touched: readers take a stored
# "imaginarium" in task.created as "ideas" (Leverage::StoredEvents).
#
# No other column holds a task state name: pending_transitions.state and
# the other state columns have their own values, and a pending transition's
# params never carry an add_task body (it names no task).
class RenameImaginariumTaskStateToIdeas < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE tasks DISABLE TRIGGER tasks_state_change_requires_event"
    execute "UPDATE tasks SET state = 'ideas' WHERE state = 'imaginarium'"
    execute "ALTER TABLE tasks ENABLE TRIGGER tasks_state_change_requires_event"
  end
end
