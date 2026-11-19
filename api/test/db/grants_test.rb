require "test_helper"
require_relative "rows"

# db:grants (lib/tasks/db_grants.rake) creates the leverage_app role and
# grants it, from information_schema, SELECT and INSERT on the append-only
# tables and SELECT, INSERT, UPDATE and DELETE on every other table, never
# TRUNCATE (PRD, Data model; C1, DB-7). It runs after db:prepare,
# db:schema:load and db:migrate, and test_helper runs it on each parallel
# worker's database.
class GrantsTest < ActiveSupport::TestCase
  include DbRows

  APPEND_ONLY = %w[events rule_versions].freeze
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
    table_names.to_h { |table| [ table, APPEND_ONLY.include?(table) ? %w[INSERT SELECT] : READ_WRITE ] }
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

  test "rights granted by hand beyond the rule are taken back" do
    db.execute("GRANT TRUNCATE, UPDATE ON events TO leverage_app")
    run_grants
    assert_equal %w[INSERT SELECT], grants["events"]
  end

  test "no fixture file exists for an append-only table (loading one truncates it)" do
    fixtures = Dir.glob(Rails.root.join("test/fixtures/**/*.yml")).map { |path| File.basename(path, ".yml") }
    assert_empty fixtures & APPEND_ONLY
  end
end
