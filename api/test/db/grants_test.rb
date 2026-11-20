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

  # No test logs in as leverage_api, and the hook may run inside a test's
  # transaction, so it leaves the role's password to db:grants.
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

  # The lock that serializes runs ends when apply returns, so a run that
  # sets the password inside a transaction someone else commits later would
  # update the role's row outside it.
  test "db:grants refuses to set leverage_api's password inside a transaction it does not own" do
    saved = ENV["LEVERAGE_API_DB_PASSWORD"]
    ENV["LEVERAGE_API_DB_PASSWORD"] = "made-up-test-password"
    original = DbGrants.method(:set_api_password)
    calls = []
    DbGrants.define_singleton_method(:set_api_password) { |*arguments| calls << arguments.last }
    assert db.transaction_open?
    error = assert_raises(ArgumentError) { DbGrants.apply(db) }
    assert_match(/transaction of its own/, error.message)
    assert_empty calls
  ensure
    DbGrants.define_singleton_method(:set_api_password, original) if original
    ENV["LEVERAGE_API_DB_PASSWORD"] = saved
  end
end

# db:grants run at once from two connections, as two containers that both
# prepare a database of one cluster would (the server's db:prepare and a
# test run's, or a restore's), or as parallel test workers do. The role
# leverage_api, and its one pg_authid row, belong to the cluster, and so
# does every advisory lock taken in one fixed database. Each pair below is
# made to overlap: the first run is held, its transaction open, just after
# it set the password, until the second run waits on a lock; only then is
# the first let go. Unserialized, the second fails with "tuple
# concurrently updated" when the first commits.
class GrantsPasswordRaceTest < CommittingTestCase
  # Two pools of their own, one for each run.
  class FirstRun < ActiveRecord::Base
    self.abstract_class = true
  end

  class SecondRun < ActiveRecord::Base
    self.abstract_class = true
  end

  WAIT = 15

  setup do
    @configured = ENV["LEVERAGE_API_DB_PASSWORD"]
    @password = @configured.to_s.empty? ? "made-up-test-password" : @configured
    ENV["LEVERAGE_API_DB_PASSWORD"] = @password
    @config = ActiveRecord::Base.connection_db_config.configuration_hash
    stem = "#{@config[:database]}_grants_race_#{SecureRandom.hex(3)}"
    @databases = [ "#{stem}_a", "#{stem}_b" ]
    @databases.each { |name| db.execute("CREATE DATABASE #{db.quote_table_name(name)}") }
    @original = DbGrants.method(:set_api_password)
  end

  teardown do
    DbGrants.define_singleton_method(:set_api_password, @original)
    [ FirstRun, SecondRun ].each(&:remove_connection)
    @databases.each { |name| db.execute("DROP DATABASE IF EXISTS #{db.quote_table_name(name)} WITH (FORCE)") }
    ENV["LEVERAGE_API_DB_PASSWORD"] = @configured
    db.execute("ALTER ROLE #{DbGrants.api_role} NOLOGIN PASSWORD NULL") if @configured.to_s.empty?
  end

  def db = ActiveRecord::Base.lease_connection

  # Runs db:grants on first and on second at once, the first held as the
  # comment above says. Returns each run's error, or nil, and whether the
  # second was seen waiting on a lock.
  def race(first, second)
    FirstRun.establish_connection(@config.merge(database: first))
    SecondRun.establish_connection(@config.merge(database: second))
    held = Queue.new
    release = Queue.new
    claimed = Mutex.new
    holding = true
    original = @original
    DbGrants.define_singleton_method(:set_api_password) do |connection, password|
      original.call(connection, password)
      hold = claimed.synchronize { holding.tap { holding = false } }
      next unless hold

      held << true
      release.pop(timeout: WAIT * 2)
    end
    second_pid = Queue.new
    first_run = Thread.new { grants(FirstRun) }
    assert held.pop(timeout: WAIT), "the first run never set the password"
    second_run = Thread.new { grants(SecondRun) { |pid| second_pid << pid } }
    waited = waits_on_lock?(second_pid.pop(timeout: WAIT))
    release << true
    [ first_run.join(WAIT * 2)&.value, second_run.join(WAIT * 2)&.value, waited ]
  ensure
    release << true
    [ first_run, second_run ].compact.each { |thread| thread.join(WAIT * 2) }
  end

  def grants(model)
    model.connection_pool.with_connection do |connection|
      yield connection.raw_connection.backend_pid if block_given?
      DbGrants.apply(connection)
    end
    nil
  rescue StandardError => error
    error
  end

  # Whether the second run's own connection, or a connection to the
  # maintenance database, waits on a lock, within WAIT seconds. Asked on
  # the raw connection: Active Record's query cache would answer the same
  # query from its first answer.
  def waits_on_lock?(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT
    loop do
      waiting = db.raw_connection.exec_params(<<~SQL, [ pid ]).getvalue(0, 0).to_i.positive?
        SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE NOT l.granted AND (l.pid = $1 OR (a.datname = 'postgres' AND l.locktype = 'advisory'))
      SQL
      return true if waiting
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def password_set?
    db.select_value("SELECT rolcanlogin AND rolpassword IS NOT NULL FROM pg_authid WHERE rolname = '#{DbGrants.api_role}'")
  end

  test "db:grants on two databases of one cluster at once both finish and leverage_api can log in" do
    first, second, waited = race(*@databases)
    assert waited, "the second run never waited on the first"
    assert_nil first, first&.message
    assert_nil second, second&.message
    assert password_set?
  end

  test "db:grants twice on one database at once both finish" do
    first, second, waited = race(@databases.first, @databases.first)
    assert waited, "the second run never waited on the first"
    assert_nil first, first&.message
    assert_nil second, second&.message
    assert password_set?
  end
end
