ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "rake"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Each worker's database is loaded from db/structure.sql, which holds no
    # grants (pg_dump --no-privileges), and no rake task runs for it: grant
    # the application role there, as db:prepare does for the main one.
    parallelize_setup do |_worker|
      DatabaseTestHooks.grant_app_role
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Fires the deferred state trigger (C7) before the test's transaction is
    # rolled back, so a test that changes tasks.state without an event for
    # that task fails here instead of passing because nothing commits.
    module FireDeferredConstraints
      def after_teardown
        DatabaseTestHooks.fire_deferred_constraints
      ensure
        super
      end
    end
    include FireDeferredConstraints
  end
end

module DatabaseTestHooks
  module_function

  # Runs db:grants (lib/tasks/db_grants.rake) on the current connection.
  def grant_app_role
    Rails.application.load_tasks unless Rake::Task.task_defined?("db:grants")
    task = Rake::Task["db:grants"]
    task.reenable
    task.invoke
  end

  def fire_deferred_constraints
    connection = ActiveRecord::Base.lease_connection
    return unless connection.transaction_open?

    connection.execute("SET CONSTRAINTS ALL IMMEDIATE")
  rescue ActiveRecord::StatementInvalid => error
    # A transaction the test already aborted cannot run the statement; the
    # rollback that follows discards it anyway.
    raise unless error.cause.is_a?(PG::InFailedSqlTransaction)
  end
end

# rails/test_help reloads the test database from db/structure.sql when the
# schema changed (maintain_test_schema), with no rake task and so no grants:
# grant the application role there too, for a run in one process.
DatabaseTestHooks.grant_app_role
