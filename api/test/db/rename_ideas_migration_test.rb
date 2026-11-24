require "test_helper"
require_relative "rows"
require Rails.root.join("db/migrate/20261124100000_rename_imaginarium_task_state_to_ideas")

# DB-52: the migration moves stored tasks from "imaginarium" to "ideas" with
# no event written, although the trigger refuses a state change with none.
# It leaves the trigger on afterwards (state_trigger_test holds that it
# refuses). The test's own transaction holds the DDL, and test_helper fires
# deferred constraints before every rollback. The migration has only up.
class RenameIdeasMigrationTest < ActiveSupport::TestCase
  include DbRows

  # ALTER TABLE is refused while a trigger event is pending, so the rows a
  # test inserted have their deferred checks run first.
  def migrate
    fire
    ActiveRecord::Migration.suppress_messages { RenameImaginariumTaskStateToIdeas.new.migrate(:up) }
  end

  def state_of(id) = sql("SELECT state FROM tasks WHERE id = $1", id).rows.first.first

  def trigger_enabled?
    sql("SELECT tgenabled FROM pg_trigger WHERE tgname = 'tasks_state_change_requires_event'").rows.first.first == "O"
  end

  test "up moves imaginarium tasks to ideas and leaves the others" do
    old = task(state: "imaginarium")
    other = task(state: "backlog")
    migrate
    assert_equal "ideas", state_of(old)
    assert_equal "backlog", state_of(other)
    assert trigger_enabled?
    fire
  end

  def fire = db.execute("SET CONSTRAINTS ALL IMMEDIATE")
end
