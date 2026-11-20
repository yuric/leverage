require "test_helper"
require_relative "rows"

# db:grants (lib/tasks/db_grants.rake) creates the leverage_app role and
# grants it, from information_schema, SELECT and INSERT on the append-only
# tables, SELECT alone on the read-only ones (backup_runs, which the owner
# role's backup writes: milestone 3 plan HB-4) and SELECT, INSERT, UPDATE
# and DELETE on every other table, never TRUNCATE (PRD, Data model; C1,
# DB-7). It runs after db:prepare,
# db:schema:load and db:migrate, and test_helper runs it on each parallel
# worker's database.
class GrantsTest < ActiveSupport::TestCase
  include DbRows

  APPEND_ONLY = %w[events rule_versions].freeze
  READ_ONLY = %w[backup_runs].freeze
  READ_WRITE = %w[DELETE INSERT SELECT UPDATE].freeze

  def grants
    sql(<<~SQL).rows.group_by(&:first).transform_values { |rows| rows.map(&:last).sort }
      SELECT table_name, privilege_type FROM information_schema.table_privileges
      WHERE grantee = 'leverage_app' AND table_schema = 'public'
    SQL
  end

  def tables
    sql(<<~SQL).rows.flatten.sort
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
    SQL
  end

  def expected_grants(table_names)
    table_names.to_h do |table|
      rights = if APPEND_ONLY.include?(table) then %w[INSERT SELECT]
      elsif READ_ONLY.include?(table) then %w[SELECT]
      else READ_WRITE
      end
      [ table, rights ]
    end
  end

  def run_grants
    DatabaseTestHooks.grant_app_role
  end

  test "the test database already carries the grants, before this test runs the task" do
    assert_equal expected_grants(tables), grants
  end

  test "the role exists and cannot log in" do
    run_grants
    assert_equal [ [ false ] ], sql("SELECT rolcanlogin FROM pg_roles WHERE rolname = 'leverage_app'").rows
  end

  # Milestone 2 plan, EN-24: the server and the sweep sign in as
  # leverage_api, a login role that holds leverage_app's rights and nothing
  # of its own. Without LEVERAGE_API_DB_PASSWORD (as in a test run) it is
  # created unable to log in.
  test "the leverage_api role exists, is a member of leverage_app and owns nothing" do
    run_grants
    member = sql(<<~SQL).rows
      SELECT r.rolinherit FROM pg_auth_members m
      JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles r ON r.oid = m.member
      WHERE g.rolname = 'leverage_app' AND r.rolname = 'leverage_api'
    SQL
    assert_equal [ [ true ] ], member
    attributes = sql("SELECT rolsuper, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname = 'leverage_api'").rows
    assert_equal [ [ false, false, false ] ], attributes
    own = sql(<<~SQL).rows
      SELECT table_name, privilege_type FROM information_schema.table_privileges
      WHERE grantee = 'leverage_api' AND table_schema = 'public'
    SQL
    assert_empty own
  end

  # Roles belong to the cluster, so a server started earlier on the same
  # cluster may have given the role its password: it logs in exactly when it
  # has one (pg_authid needs the owner role, which every test run uses).
  test "the leverage_api role can log in only when it was given a password" do
    run_grants
    assert_equal [ [ true ] ], sql(<<~SQL).rows
      SELECT rolcanlogin = (rolpassword IS NOT NULL) FROM pg_authid WHERE rolname = 'leverage_api'
    SQL
  end

  test "the role holds exactly the expected rights on every table, and no TRUNCATE" do
    run_grants
    assert_equal expected_grants(tables), grants
    refute grants.values.flatten.include?("TRUNCATE")
  end

  test "running the task twice changes nothing" do
    run_grants
    before = grants
    run_grants
    assert_equal before, grants
  end

  test "a table added later gets the default rights when the task runs" do
    db.execute("CREATE TABLE made_up_later (id uuid PRIMARY KEY)")
    run_grants
    assert_equal READ_WRITE, grants["made_up_later"]
  end

  # Milestone 3 plan HB-4: the application's role reads when the last
  # backup ran and writes nothing of it.
  test "leverage_app may only read backup_runs, even after rights granted by hand" do
    run_grants
    assert_equal %w[SELECT], grants["backup_runs"]
    db.execute("GRANT INSERT, UPDATE, DELETE, TRUNCATE ON backup_runs TO leverage_app")
    run_grants
    assert_equal %w[SELECT], grants["backup_runs"]
  end

  test "rights granted by hand beyond the rule are taken back" do
    db.execute("GRANT TRUNCATE, UPDATE ON events TO leverage_app")
    run_grants
    assert_equal %w[INSERT SELECT], grants["events"]
  end

  test "no fixture file exists for an append-only table (loading one truncates it)" do
    fixtures = Dir.glob(Rails.root.join("test/fixtures/**/*.yml")).map { |path| File.basename(path, ".yml") }
    assert_empty fixtures & APPEND_ONLY
  end

  # The parallel test workers each run the hook at once, and ALTER ROLE on
  # one pg_authid row from several transactions fails with "tuple
  # concurrently updated". No test logs in as leverage_api, so the hook
  # leaves its password to db:grants.
  test "the test hook grants the rights but never sets leverage_api's password, even when one is configured" do
    saved = ENV["LEVERAGE_API_DB_PASSWORD"]
    ENV["LEVERAGE_API_DB_PASSWORD"] = "made-up-test-password"
    original = DbGrants.method(:set_api_password)
    calls = []
    DbGrants.define_singleton_method(:set_api_password) { |*arguments| calls << arguments.last }
    run_grants
    assert_empty calls, "the test hook set leverage_api's password"
    assert_equal expected_grants(tables), grants
  ensure
    DbGrants.define_singleton_method(:set_api_password, original) if original
    ENV["LEVERAGE_API_DB_PASSWORD"] = saved
  end
end

# db:grants run at once from several connections, as two containers that
# both prepare the database would: setting leverage_api's password is
# serialized, so no run fails with "tuple concurrently updated".
class GrantsPasswordRaceTest < CommittingTestCase
  test "concurrent password updates of leverage_api all succeed" do
    configured = ENV["LEVERAGE_API_DB_PASSWORD"].to_s
    password = configured.empty? ? "made-up-test-password" : configured
    DatabaseTestHooks.grant_app_role
    errors = Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.transaction do
            DbGrants.set_api_password(connection, password)
            connection.execute("SELECT pg_sleep(0.2)")
          end
        end
        nil
      rescue StandardError => error
        error
      end
    end.map(&:value).compact
    assert_empty errors.map(&:message)
  ensure
    if configured.to_s.empty?
      ActiveRecord::Base.lease_connection.execute("ALTER ROLE #{DbGrants.api_role} NOLOGIN PASSWORD NULL")
    end
  end
end
