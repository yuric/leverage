# db:grants: the leverage_app database role and its rights (PRD, Data model:
# "The application's database role has no right to update or delete" the
# events; plan DB-7). db/structure.sql carries no grants (Rails dumps it with
# pg_dump --no-privileges), so they are applied by this task, after every
# task that builds or changes the schema, and by test/test_helper.rb on each
# parallel test worker's database. The append-only triggers hold whatever
# the role.
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
# statement logging turned off and never through the Rails logger.
#
# Methods, not constants: `bin/rails test` loads the tasks into a Rake
# application of its own, and test_helper loads them again into the default
# one, which would warn about constants defined twice.
module DbGrants
  module_function

  def role = "leverage_app"
  def api_role = "leverage_api"
  def append_only = %w[events rule_versions]

  def apply(connection)
    connection.transaction do
      create_role(connection)
      connection.execute("GRANT USAGE ON SCHEMA public TO #{role}")
      tables(connection).each do |table|
        quoted = connection.quote_table_name(table)
        rights = append_only.include?(table) ? "SELECT, INSERT" : "SELECT, INSERT, UPDATE, DELETE"
        connection.execute("REVOKE ALL ON #{quoted} FROM #{role}")
        connection.execute("GRANT #{rights} ON #{quoted} TO #{role}")
      end
      connection.execute("GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO #{role}")
      create_api_role(connection)
      set_api_password(connection, ENV["LEVERAGE_API_DB_PASSWORD"].to_s)
    end
  end

  # Like create_role, safe when parallel test workers race: a worker that
  # loses either step finds the role, or the membership, already there.
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

  # Roles belong to the cluster, so parallel test workers may race to create
  # it; the loser's error is caught inside the block.
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
