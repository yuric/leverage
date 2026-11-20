# db:grants: the leverage_app database role and its rights (PRD, Data model:
# "The application's database role has no right to update or delete" the
# events; plan DB-7). db/structure.sql carries no grants (Rails dumps it with
# pg_dump --no-privileges), so they are applied by this task, after every
# task that builds or changes the schema, and by test/test_helper.rb on each
# parallel test worker's database. The append-only triggers hold whatever
# the role. On backup_runs, which the owner role's backup writes, the role
# may only read (milestone 3 plan HB-4).
#
# The rights are computed from information_schema, so a table added by a
# later migration needs no grant of its own. Running the task twice changes
# nothing: each table's rights are revoked and granted again in full.
#
# It also creates leverage_api, the login role the server and the sweep
# connect as (milestone 2 plan EN-24): a member of leverage_app with no
# right of its own. Its password is LEVERAGE_API_DB_PASSWORD; without that
# variable the role is created unable to log in, and an existing role is
# left as it is. The statement that sets the password is sent with
# statement logging turned off and never through the Rails logger. The test
# hook skips it (password: false): no test logs in as leverage_api.
#
# Two runs at once, on one database or on two of the same cluster (the
# server's db:prepare and a test run's, a db:migrate beside the server's
# start, or restores in parallel test workers), would update the same
# catalog rows together: the role's pg_authid row, which belongs to the
# cluster, when both set the password, and in one database the schema's
# and the tables' grants. PostgreSQL fails the second with
# "tuple concurrently updated" once the first commits. So each run holds a
# session advisory lock from before its transaction begins until after it
# ends, taken on a connection of its own to the maintenance database
# "postgres": an advisory lock belongs to the database it is taken in, so
# one fixed database makes it one lock for the whole cluster. A run that
# sets the password needs its transaction to be its own, or the lock would
# end before the commit.
#
# Methods, not constants: `bin/rails test` loads the tasks into a Rake
# application of its own, and test_helper loads them again into the default
# one, which would warn about constants defined twice.
module DbGrants
  module_function

  def role = "leverage_app"
  def api_role = "leverage_api"
  def append_only = %w[events rule_versions]
  # Tables the application's role may only read: the owner role's backup
  # writes backup_runs (milestone 3 plan HB-4).
  def read_only = %w[backup_runs]

  # The advisory lock that serializes every run, in the maintenance
  # database: "lvpw" in ASCII.
  def lock_key = 0x6c767077
  def lock_database = "postgres"

  # password: false leaves leverage_api's password as it is.
  def apply(connection, password: true)
    secret = password ? ENV["LEVERAGE_API_DB_PASSWORD"].to_s : ""
    if !secret.empty? && connection.transaction_open?
      raise ArgumentError, "db:grants sets leverage_api's password only in a transaction of its own"
    end

    one_at_a_time(connection) { grant(connection, secret) }
  end

  def grant(connection, secret)
    connection.transaction do
      create_role(connection)
      connection.execute("GRANT USAGE ON SCHEMA public TO #{role}")
      tables(connection).each do |table|
        quoted = connection.quote_table_name(table)
        rights = rights_on(table)
        connection.execute("REVOKE ALL ON #{quoted} FROM #{role}")
        connection.execute("GRANT #{rights} ON #{quoted} TO #{role}")
      end
      connection.execute("GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO #{role}")
      create_api_role(connection)
      set_api_password(connection, secret) unless secret.empty?
    end
  end

  # Runs the block holding the cluster-wide lock, on a connection of its
  # own to lock_database with the same server, user and password as
  # connection's. Closing that connection gives the lock back, also when
  # the block raises.
  def one_at_a_time(connection)
    settings = connection.raw_connection.conninfo_hash.compact.merge(dbname: lock_database)
    lock = PG.connect(settings)
    lock.exec("SELECT pg_advisory_lock(#{lock_key})")
    yield
  ensure
    lock&.close
  end

  def rights_on(table)
    if append_only.include?(table) then "SELECT, INSERT"
    elsif read_only.include?(table) then "SELECT"
    else "SELECT, INSERT, UPDATE, DELETE"
    end
  end

  # Like create_role, safe even without the lock: a run that loses either
  # step finds the role, or the membership, already there.
  def create_api_role(connection)
    connection.execute(<<~SQL)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{api_role}') THEN
          CREATE ROLE #{api_role} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT;
        END IF;
      EXCEPTION WHEN duplicate_object OR unique_violation THEN
        NULL;
      END
      $$;
    SQL
    connection.execute(<<~SQL)
      DO $$
      BEGIN
        IF NOT pg_has_role('#{api_role}', '#{role}', 'MEMBER') THEN
          GRANT #{role} TO #{api_role};
        END IF;
      EXCEPTION WHEN OTHERS THEN
        IF NOT pg_has_role('#{api_role}', '#{role}', 'MEMBER') THEN
          RAISE;
        END IF;
      END
      $$;
    SQL
  end

  # Sent on the raw connection, so neither the Rails log nor a notification
  # subscriber sees it; log_statement is turned off for this transaction
  # where the owner role may do so.
  def set_api_password(connection, password)
    return if password.empty?

    raw = connection.raw_connection
    superuser = raw.exec("SELECT rolsuper FROM pg_roles WHERE rolname = current_user").getvalue(0, 0)
    raw.exec("SET LOCAL log_statement = 'none'") if superuser == "t" || superuser == true
    raw.exec("ALTER ROLE #{api_role} LOGIN PASSWORD #{raw.escape_literal(password)}")
  end

  # Roles belong to the cluster, so two runs may race to create it; the
  # loser's error is caught inside the block.
  def create_role(connection)
    connection.execute(<<~SQL)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{role}') THEN
          CREATE ROLE #{role} NOLOGIN;
        END IF;
      EXCEPTION WHEN duplicate_object OR unique_violation THEN
        NULL;
      END
      $$;
    SQL
  end

  def tables(connection)
    connection.select_values(<<~SQL)
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      ORDER BY table_name
    SQL
  end
end

namespace :db do
  desc "Create the leverage_app role, grant it its rights on every table, and create the leverage_api login role"
  task grants: :environment do
    DbGrants.apply(ActiveRecord::Base.lease_connection)
  end
end

%w[db:prepare db:schema:load db:migrate].each do |name|
  Rake::Task[name].enhance do
    Rake::Task["db:grants"].reenable
    Rake::Task["db:grants"].invoke
  end
end
