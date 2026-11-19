require "test_helper"

# Leverage::WorkspaceLock (PRD L217-L218; DB-4, DB-5): the first statement
# of a change locks the workspace row, and a second one reads the clock,
# so at is read only once the lock is held.
class WorkspaceLockTest < ActiveSupport::TestCase
  def statements
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    yield
    seen
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "the lock is the first statement and the clock the second" do
    scenario = Scenario.new
    sql = statements { Leverage::WorkspaceLock.take(scenario.workspace_id) }

    assert_equal 2, sql.size, sql.inspect
    assert_match(/\ASELECT .*FROM "workspaces" WHERE "workspaces"\."id" = .* FOR UPDATE\z/m, sql.first)
    assert_equal "SELECT clock_timestamp()", sql.second
  end

  test "it answers the locked row and the database clock" do
    scenario = Scenario.new
    workspace, at = Leverage::WorkspaceLock.take(scenario.workspace_id)
    _, later = Leverage::WorkspaceLock.take(scenario.workspace_id)

    assert_equal scenario.workspace_id, workspace.id
    assert_kind_of Time, at
    assert_operator later, :>, at, "clock_timestamp moves inside one transaction"
  end

  test "an unknown workspace is not found" do
    assert_raises(ActiveRecord::RecordNotFound) { Leverage::WorkspaceLock.take(SecureRandom.uuid) }
  end

  test "setup, which has no workspace yet, takes a fixed advisory lock" do
    sql = statements { assert_kind_of Time, Leverage::WorkspaceLock.take_setup }

    assert_match(/\ASELECT pg_advisory_xact_lock\(\d+\)\z/, sql.first)
    assert_equal "SELECT clock_timestamp()", sql.second
  end
end

# The lock holds until commit: a second transaction waits for it.
class WorkspaceLockWaitTest < CommittingTestCase
  def try_lock_elsewhere
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        ActiveRecord::Base.transaction do
          connection.execute("SET LOCAL lock_timeout = '200ms'")
          Leverage::WorkspaceLock.take(scenario.workspace_id)
          :locked
        end
      rescue ActiveRecord::LockWaitTimeout
        :waited
      end
    end.value
  end

  test "a second transaction cannot take the lock until the first commits" do
    ActiveRecord::Base.transaction do
      Leverage::WorkspaceLock.take(scenario.workspace_id)
      assert_equal :waited, try_lock_elsewhere
    end
    assert_equal :locked, try_lock_elsewhere
  end
end
