require "test_helper"
require_relative "rows"

# events and rule_versions accept inserts only (PRD, Data model; C1, C14,
# C22). Triggers refuse UPDATE, DELETE and TRUNCATE for every role, the
# connecting superuser included; the leverage_app role also lacks the
# privilege. A superuser or the table owner can still switch the triggers
# off, so the guarantee holds once the API logs in as leverage_app (Core
# loop); these tests prove the triggers and the grants, not that switch. This runs on the test worker's own database, which is loaded
# from db/structure.sql, the path CI takes.
class AppendOnlyTest < ActiveSupport::TestCase
  include DbRows

  APPEND_ONLY = %w[events rule_versions].freeze

  # Runs the block as leverage_app, inside a savepoint so that a refused
  # statement and the role change both end with it.
  def as_app_role(&block)
    in_savepoint do
      db.execute("SET LOCAL ROLE leverage_app")
      block.call
    end
  end

  def rows
    { "events" => event, "rule_versions" => rule_version }
  end

  test "the connecting role is the superuser this test needs to prove the triggers hold for it" do
    assert_equal "on", sql("SHOW is_superuser").rows.first.first
  end

  APPEND_ONLY.each do |table|
    test "#{table}: the connecting role may insert and select" do
      id = rows.fetch(table)
      assert_equal 1, sql("SELECT count(*) FROM #{table} WHERE id = $1", id).rows.first.first
    end

    test "#{table}: the connecting role cannot update, delete or truncate" do
      id = rows.fetch(table)
      # TRUNCATE ... CASCADE reaches rules, whose deferred current-version
      # key is still pending from the insert; checking it now leaves the
      # append-only trigger as the only thing that can refuse.
      db.execute("SET CONSTRAINTS ALL IMMEDIATE")
      [
        "UPDATE #{table} SET created_at = created_at WHERE id = '#{id}'",
        "DELETE FROM #{table} WHERE id = '#{id}'",
        "TRUNCATE #{table} CASCADE"
      ].each do |statement|
        error = assert_rejected { db.execute(statement) }
        assert_match(/#{table} is append-only/, error.message, statement)
      end
      assert_equal 1, sql("SELECT count(*) FROM #{table} WHERE id = $1", id).rows.first.first
    end

    test "#{table}: leverage_app may insert and select" do
      id = rows.fetch(table)
      error = as_app_role do
        assert_equal 1, sql("SELECT count(*) FROM #{table} WHERE id = $1", id).rows.first.first
        table == "events" ? event : insert("rule_versions", workspace_id: workspace, rule_id: rule, version: 2,
          key: "made_up_rule", name: "A made-up rule", hook: "task.before_ready", scope_kind: "all_tasks",
          kind: "gate", checker: "app", origin: "custom", author_kind: "owner")
      end
      assert_nil error, -> { error.message }
    end

    test "#{table}: leverage_app has no right to update, delete or truncate" do
      id = rows.fetch(table)
      [
        "UPDATE #{table} SET created_at = created_at WHERE id = '#{id}'",
        "DELETE FROM #{table} WHERE id = '#{id}'",
        "TRUNCATE #{table} CASCADE"
      ].each do |statement|
        error = as_app_role { db.execute(statement) }
        assert_kind_of PG::InsufficientPrivilege, error&.cause, statement
      end
    end
  end

  test "a plain TRUNCATE of events is refused too" do
    event
    assert_rejected { db.execute("TRUNCATE events") }
  end

  test "leverage_app may update a mutable table such as tasks" do
    task_id = task
    error = as_app_role do
      sql("UPDATE tasks SET priority = 'high' WHERE id = $1", task_id)
    end
    assert_nil error, -> { error.message }
    assert_equal "high", sql("SELECT priority FROM tasks WHERE id = $1", task_id).rows.first.first
  end

  test "the connecting role may update tasks" do
    task_id = task
    assert_accepted { sql("UPDATE tasks SET priority = 'low' WHERE id = $1", task_id) }
  end
end
