require "open3"
require "pg"

module Leverage
  # The daily backup and the maintainer's restore (milestone 3 plan §2.5,
  # HB-1 to HB-8; PRD L829, L921).
  #
  # The database is the one this program is configured for, read from
  # ActiveRecord::Base.connection_db_config without opening a connection:
  # DATABASE_URL names no database, so no PostgreSQL tool is ever handed
  # it. Its host, port, user and name go to the tools as arguments, and its
  # password only in PGPASSWORD, never in an argument (Target).
  #
  # A backup (bin/backup) runs pg_dump in custom format, with no grant
  # (--no-privileges), into leverage-<UTC time>.dump.partial, opened with mode 0600,
  # renames the finished file to .dump, writes one backup_runs row for it
  # and prunes: only the files this database's rows name, beyond the newest
  # KEEP, each with its row. A file no row names is never touched. A failed
  # dump removes its partial file, writes no row and logs one line naming
  # the folder; the loop tries again at its next look.
  #
  # A restore (bin/restore) makes the database again from a dump: it
  # refuses a database whose events table holds a row unless replace is
  # given, checks that pg_restore can read the dump's list, creates a
  # staging database beside it, runs pg_restore into that (the tables
  # and rows first, then, once every restored event's transaction id is
  # set to 0, the indexes and triggers) with no
  # --create and no --clean, and with --no-owner (pg_dump ignores
  # --no-owner for an archive format, so the dump keeps each object's
  # owner and the restore drops it: a new cluster may lack that role),
  # runs there the migrations the dump has not seen (a dump carries the
  # schema of the day it was made, and the replay test reads today's; a
  # dump that names a migration this version does not have is refused),
  # gives the roles their rights again
  # (db:grants: a dump of one database holds no role) and runs
  # leverage:verify_log there. Only then is the database dropped and the
  # staging database renamed to its name, so a dump that cannot be
  # restored leaves the database as it was. One path, whatever was there
  # before.
  module Backup
    # bin/backup looks when it starts and then every 15 minutes (HB-3);
    # while the database holds no workspace it makes no dump and looks
    # again every 30 seconds, so the first dump follows the owner's sign-up.
    LOOK_EVERY = 15 * 60
    EMPTY_LOOK_EVERY = 30
    EMPTY_LINE = "The database holds no workspace yet: no dump until the owner signs up.".freeze
    EVERY_HOURS = 24
    KEEP = 14
    FOLDER = "/backups".freeze
    LOG = "leverage.backup".freeze
    # The only names a backup writes, and so the only files pruning removes.
    NAME = /\Aleverage-\d{8}T\d{9}Z\.dump\z/
    PARTIAL = ".partial".freeze
    MAINTENANCE_DATABASE = "postgres".freeze
    DUMP_FLAGS = %w[--format=custom --no-owner --no-privileges].freeze
    RESTORE_FLAGS = %w[--no-owner --no-privileges --exit-on-error].freeze
    # A restore is made into <database>_restoring_<hex> first, and takes
    # the database's name only once it has passed the replay test.
    STAGING = "_restoring_".freeze

    class Failed < StandardError; end
    # A restore that would replace a log, without replace.
    class Refused < Failed; end

    # Where a PostgreSQL tool connects. The password is never in an
    # argument, and never in inspect.
    Target = Data.define(:host, :port, :username, :password, :database) do
      def self.current(db_config = ActiveRecord::Base.connection_db_config)
        hash = db_config.configuration_hash
        new(host: hash[:host], port: hash[:port], username: hash[:username], password: hash[:password],
          database: hash[:database])
      end

      # The child's environment: the password, and no default database a
      # tool could fall back on.
      def env = { "PGPASSWORD" => password.to_s, "PGDATABASE" => nil, "PGSERVICE" => nil }

      def connection_args
        { "--host" => host, "--port" => port, "--username" => username }
          .reject { |_flag, value| value.to_s.empty? }.flat_map { |flag, value| [ flag, value.to_s ] }
      end

      def inspect = "#<Leverage::Backup::Target #{username}@#{host}:#{port}/#{database}>"
      alias_method :to_s, :inspect
    end

    SPAWN = ->(env, argv, **redirects) { Process.spawn(env, *argv, **redirects) }

    module_function

    # Whether the database holds something to keep and no backup_runs row
    # is newer than every_hours, by the database's clock. A database with
    # no workspace (a new one, as after the volume was lost) is never
    # dumped: its dump would become the newest file in the folder, beside
    # the dumps of the log that was lost.
    def due?(every_hours: EVERY_HOURS)
      !empty? && !BackupRun.where("ran_at > ?", database_now - every_hours.to_f.hours).exists?
    end

    # Whether the database holds no workspace yet: no owner has signed up.
    def empty? = !Workspace.exists?

    # One backup. Returns its BackupRun, or nil when it failed (logged).
    def run(folder: FOLDER, keep: KEEP, target: nil, spawner: SPAWN, log: nil)
      run!(folder: folder, keep: keep, target: target, spawner: spawner)
    rescue Failed => error
      (log || method(:log_error)).call("#{LOG} failed folder=#{folder} reason=#{error.message.inspect}")
      nil
    end

    # One backup. Returns its BackupRun, or raises Failed with nothing left
    # behind: no partial file, no row.
    def run!(folder: FOLDER, keep: KEEP, target: nil, spawner: SPAWN)
      target ||= Target.current
      at = database_now
      name = "leverage-#{at.utc.strftime("%Y%m%dT%H%M%S%LZ")}.dump"
      path = File.join(folder, name)
      partial = path + PARTIAL
      dump(target, partial, spawner)
      File.chmod(0o600, partial)
      File.rename(partial, path)
      record(path, name, at).tap { prune(folder, keep: keep) }
    rescue SystemCallError => error
      raise Failed, "#{error.class.name.demodulize}: #{error.message}"
    ensure
      remove_quietly(partial) if partial
    end

    # Removes the files of the rows beyond the newest keep, each with its
    # row. A row whose file cannot be removed is kept, to be tried again.
    # Returns the file names removed.
    def prune(folder, keep: KEEP)
      BackupRun.order(ran_at: :desc, id: :desc).offset(keep).filter_map do |row|
        path = File.join(folder, row.file_name)
        begin
          File.delete(path) if NAME.match?(row.file_name) && File.file?(path)
        rescue SystemCallError => error
          log_error("#{LOG} prune folder=#{folder} file=#{row.file_name} reason=#{error.message.inspect}")
          next
        end
        row.delete
        row.file_name
      end
    end

    # bin/backup: a look when it starts and then every look_every seconds
    # (every EMPTY_LOOK_EVERY while the database holds no workspace), until
    # stop answers true; a backup at each look where one is due. say is
    # told EMPTY_LINE once while the database holds no workspace. A
    # look that fails is logged and the next one runs on time. The sleeper,
    # stop and the module are parameters, so the loop is tested without
    # waiting.
    def run_loop(folder: FOLDER, keep: KEEP, every_hours: EVERY_HOURS, look_every: LOOK_EVERY, stop: -> { false },
                 sleeper: nil, log: nil, say: nil, backup: self)
      log ||= method(:log_error)
      sleeper ||= ->(seconds) { pause(seconds, stop) }
      said = false
      until stop.call
        wait = look_every
        begin
          if backup.empty?
            wait = [ EMPTY_LOOK_EVERY, look_every ].min
            say&.call(EMPTY_LINE) unless said
            said = true
          elsif backup.due?(every_hours: every_hours)
            backup.run(folder: folder, keep: keep, log: log)
          end
        rescue StandardError => error
          log.call("#{LOG} look failed folder=#{folder} error=#{error.class} message=#{error.message.inspect}")
        end
        sleeper.call(wait) unless stop.call
      end
    end

    # bin/restore. Raises Refused over a log without replace, Failed when a
    # step fails; returns the target restored. workspace_id limits the
    # replay test to one workspace (tests); the maintainer's restore checks
    # them all.
    def restore(file, replace: false, target: nil, workspace_id: nil, spawner: SPAWN)
      target ||= Target.current
      raise Failed, "There is no dump at #{file}." unless File.file?(file) && File.readable?(file)

      if holds_events?(target) && !replace
        raise Refused, "The database #{target.database} holds events. Nothing was changed. " \
                       "To replace it with the dump, run bin/restore again with --replace."
      end

      tool!(target, spawner, "pg_restore", "--list", file)
      staging = target.with(database: "#{target.database}#{STAGING}#{SecureRandom.hex(4)}")
      restore_into(staging, file, workspace_id, spawner)
      replace_with(target, staging, spawner)
      target
    end

    # Makes staging from the dump, brings its schema to this version's,
    # gives the roles their rights (after the migrations, so that a table
    # they add has its own) and runs the replay test there. On any
    # failure, of whatever kind, staging is dropped, the target was never
    # touched, and the error is a Failed.
    def restore_into(staging, file, workspace_id, spawner)
      tool!(staging, spawner, "createdb", *staging.connection_args, "--maintenance-db=#{MAINTENANCE_DATABASE}",
        staging.database)
      pg_restore!(staging, spawner, file, "pre-data", "data")
      forget_transaction_ids(staging)
      pg_restore!(staging, spawner, file, "post-data")
      connected_to(staging) do
        load_tasks
        migrate!
        DbGrants.apply(ActiveRecord::Base.lease_connection)
        verify!(workspace_id)
      end
    rescue StandardError => error
      drop_quietly(staging, spawner)
      raise if error.is_a?(Failed)

      raise Failed, "#{error.class.name}: #{first_line(error.message)}"
    end

    # pg_restore of the named sections of the dump into staging. The
    # tables and their rows are pre-data and data; the indexes, the
    # constraints and the triggers are post-data.
    def pg_restore!(staging, spawner, file, *sections)
      tool!(staging, spawner, "pg_restore", *RESTORE_FLAGS, *sections.map { |section| "--section=#{section}" },
        *staging.connection_args, "--dbname", staging.database, file)
    end

    # Gives every restored event the transaction id 0. events.xact_id
    # holds the id of the transaction that wrote the row, and the state
    # trigger lets a task's state change only when an event of the task
    # carries the current transaction's id (DB-6). An id means something
    # only in the cluster that issued it: a new cluster, as after a lost
    # volume, issues the same numbers again, and a restored row would then
    # stand in for an event that a later transaction never wrote. No
    # transaction has the id 0. Done between the data and the triggers,
    # so the append-only trigger is not there yet and is never switched
    # off.
    def forget_transaction_ids(staging)
      with_pg(staging, staging.database) do |pg|
        next if pg.exec("SELECT to_regclass('public.events')").getvalue(0, 0).nil?

        pg.exec("UPDATE public.events SET xact_id = '0'")
      end
    end

    # Drops the target and gives staging its name. A target that cannot be
    # dropped is kept as it was, and staging is dropped with it named in
    # the message; between the drop and the rename, the message says to
    # rename staging by hand.
    def replace_with(target, staging, spawner)
      begin
        drop_database(target, spawner: spawner)
      rescue Failed => error
        drop_quietly(staging, spawner)
        raise Failed, "the database #{target.database} could not be dropped, so it was kept as it was " \
                      "and the restored copy #{staging.database} was removed: #{error.message}"
      end
      rename_database(target, from: staging.database)
    end

    def drop_quietly(target, spawner)
      drop_database(target, spawner: spawner)
    rescue Failed
      nil
    end

    # Gives the database from its name the target's, over the maintenance
    # database.
    def rename_database(target, from:)
      with_pg(target, MAINTENANCE_DATABASE) do |pg|
        pg.exec("ALTER DATABASE #{pg.quote_ident(from)} RENAME TO #{pg.quote_ident(target.database)}")
      end
    rescue Failed => error
      raise Failed, "the restored database #{from} could not take the name #{target.database} " \
                    "(rename it by hand): #{error.message}"
    end

    def drop_database(target, spawner: SPAWN)
      tool!(target, spawner, "dropdb", *target.connection_args, "--maintenance-db=#{MAINTENANCE_DATABASE}",
        "--if-exists", target.database)
    end

    def database_exists?(target)
      with_pg(target, MAINTENANCE_DATABASE) do |pg|
        pg.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [ target.database ]).ntuples == 1
      end
    end

    # Whether the database exists and its events table holds a row.
    def holds_events?(target)
      return false unless database_exists?(target)

      with_pg(target, target.database) do |pg|
        next false if pg.exec("SELECT to_regclass('public.events')").getvalue(0, 0).nil?

        pg.exec("SELECT EXISTS (SELECT 1 FROM public.events)").getvalue(0, 0) == "t"
      end
    end

    # --- private -------------------------------------------------------------

    def dump(target, partial, spawner)
      reader, writer = IO.pipe
      argv = [ "pg_dump", *DUMP_FLAGS, *target.connection_args, "--dbname", target.database ]
      pid = spawner.call(target.env, argv, in: File::NULL,
        out: [ partial, File::WRONLY | File::CREAT | File::EXCL, 0o600 ], err: writer)
      writer.close
      message = reader.read
      _pid, status = Process.wait2(pid)
      raise Failed, "pg_dump exited #{status.exitstatus}: #{first_line(message)}" unless status.success?
    ensure
      writer&.close unless writer&.closed?
      reader&.close
    end

    # The row for a finished dump. A row that cannot be written takes its
    # file with it, so no dump is left that pruning would never remove.
    def record(path, name, at)
      BackupRun.create!(ran_at: at, file_name: name, bytes: File.size(path))
    rescue ActiveRecord::ActiveRecordError => error
      remove_quietly(path)
      raise Failed, "the backup_runs row was not written: #{error.class.name.demodulize}"
    end

    # Runs a PostgreSQL tool and raises Failed with its own message when it
    # fails.
    def tool!(target, spawner, *argv)
      reader, writer = IO.pipe
      pid = spawner.call(target.env, argv, in: File::NULL, out: writer, err: writer)
      writer.close
      message = reader.read
      _pid, status = Process.wait2(pid)
      raise Failed, "#{argv.first} failed: #{message.strip}" unless status.success?
    rescue SystemCallError => error
      raise Failed, "#{argv.first} could not run: #{error.message}"
    ensure
      writer&.close unless writer&.closed?
      reader&.close
    end

    def with_pg(target, database)
      pg = PG.connect(host: target.host, port: target.port, user: target.username, password: target.password,
        dbname: database)
      yield pg
    rescue PG::Error => error
      raise Failed, "could not reach #{database}: #{first_line(error.message)}"
    ensure
      pg&.close
    end

    # Runs the block connected to the target's database, and gives the
    # connection back after.
    def connected_to(target)
      original = ActiveRecord::Base.connection_db_config
      return yield if original.database == target.database

      begin
        ActiveRecord::Base.establish_connection(original.configuration_hash.merge(database: target.database))
        yield
      ensure
        ActiveRecord::Base.establish_connection(original)
      end
    end

    # Runs, on the database now connected, every migration its
    # schema_migrations does not name, as the owner role: what the server's
    # db:prepare would do at its next start, done here so that the replay
    # test reads the columns it expects. Nothing to run when the dump is of
    # this version. A dump that names a migration this version does not
    # have was made by a later one, whose log this code cannot vouch for
    # and whose schema no migration here takes back: it is refused. No
    # schema file is written.
    def migrate!
      pool = ActiveRecord::Base.connection_pool
      context = ActiveRecord::MigrationContext.new(Rails.application.paths["db/migrate"].existent,
        pool.schema_migration, pool.internal_metadata)
      unknown = context.get_all_versions - context.migrations.map(&:version)
      unless unknown.empty?
        raise Failed, "the dump was made by a later version of Leverage than this one (it names the " \
                      "migration #{unknown.max}, which this version does not have). Restore it with that version."
      end

      context.migrate
      ActiveRecord::Base.descendants.each(&:reset_column_information)
    end

    def verify!(workspace_id)
      task = Rake::Task["leverage:verify_log"]
      task.reenable
      saved = ENV.fetch("WORKSPACE_ID", nil)
      ENV["WORKSPACE_ID"] = workspace_id
      task.invoke
    rescue SystemExit => error
      raise Failed, "the restored log does not pass the replay test (leverage:verify_log)" unless error.success?
    ensure
      ENV["WORKSPACE_ID"] = saved
    end

    # db:grants and leverage:verify_log live in lib/tasks.
    def load_tasks
      require "rake"
      return if Rake::Task.task_defined?("db:grants") && Rake::Task.task_defined?("leverage:verify_log")

      Rails.application.load_tasks
    end

    def database_now
      ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
    end

    def remove_quietly(path)
      File.delete(path) if File.exist?(path)
    rescue SystemCallError
      nil
    end

    def first_line(text) = text.to_s.strip.lines.first.to_s.strip

    def log_error(line)
      Rails.logger.error(line)
    end

    def pause(seconds, stop)
      deadline = monotonic + seconds
      sleep([ 1, deadline - monotonic ].min) while !stop.call && monotonic < deadline
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
