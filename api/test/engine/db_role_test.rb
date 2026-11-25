require "test_helper"

# The server and the sweep connect as leverage_api (milestone 2 plan EN-24;
# DB-7, accepted for "the first writer"): a member of leverage_app, which
# may insert events and never update or delete them. The test switches its
# own transaction to the role, so the database itself is what refuses.
class DbRoleTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @task = @scenario.task
  end

  def as_api_role
    db = ActiveRecord::Base.lease_connection
    db.transaction(requires_new: true) do
      db.execute("SET LOCAL ROLE leverage_api")
      yield db
    ensure
      db.execute("RESET ROLE") unless db.raw_connection.transaction_status == PG::PQTRANS_INERROR
    end
  end

  def refused
    error = assert_raises(ActiveRecord::StatementInvalid) { as_api_role { |db| yield db } }
    assert_match(/permission denied/, error.message)
  end

  test "under leverage_api an UPDATE of events is refused by the database" do
    refused { |db| db.execute("UPDATE events SET payload = payload WHERE workspace_id = #{db.quote(@scenario.workspace_id)}") }
  end

  test "under leverage_api a DELETE or TRUNCATE of events is refused by the database" do
    refused { |db| db.execute("DELETE FROM events WHERE workspace_id = #{db.quote(@scenario.workspace_id)}") }
    refused { |db| db.execute("TRUNCATE events") }
  end

  # Rails' bookkeeping tables decide which migrations the owner role runs
  # at the next server start, so the login role only reads them.
  test "under leverage_api schema_migrations and ar_internal_metadata can be read and not written" do
    as_api_role { |db| assert_operator db.select_value("SELECT count(*) FROM schema_migrations"), :>, 0 }
    refused { |db| db.execute("INSERT INTO schema_migrations (version) VALUES ('29991231235959')") }
    refused { |db| db.execute("DELETE FROM schema_migrations") }
    refused { |db| db.execute("UPDATE ar_internal_metadata SET value = value") }
    refused { |db| db.execute("DELETE FROM ar_internal_metadata") }
  end

  test "under leverage_api the transition function still writes: an event, a task and a commands row" do
    entry = Class.new(Leverage::Transitions::Entry) do
      def perform(ctx)
        task = Task.create!(workspace_id: ctx.workspace.id, state: "backlog")
        ctx.emit("task.created", task: task, schema_version: 1, payload: { state: "backlog", added_action_ids: [] })
        @result = {}
      end
    end
    owner = @scenario.owner
    request = Leverage::Transitions::Request.new(command: "add_task", workspace_id: @scenario.workspace_id,
      caller_kind: "owner", caller_id: owner.id, key: "as-api-role", request_hash: "0" * 64, params: {})

    outcome = as_api_role do |db|
      assert_equal "leverage_api", db.select_value("SELECT current_user")
      Leverage::Transitions::Table.with_entries("add_task" => entry) { Leverage::Transitions.apply(request) }
    end
    assert_equal :completed, outcome.outcome
    assert Command.exists?(key: "as-api-role")
  end
end
