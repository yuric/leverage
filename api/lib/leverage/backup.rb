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
  # given, drops and creates the database, runs pg_restore into it with no
  # --create and no --clean, and with --no-owner (pg_dump ignores
  # --no-owner for an archive format, so the dump keeps each object's
  # owner and the restore drops it: a new cluster may lack that role), gives the roles their rights again
  # (db:grants: a dump of one database holds no role) and runs
  # leverage:verify_log. One path, whatever was there before.
  module Backup
    # bin/backup looks when it starts and then every 15 minutes (HB-3).
    LOOK_EVERY = 15 * 60
    EMPTY_LOOK_EVERY = 30
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

    # Whether no backup_runs row is newer than every_hours, by the
    # database's clock.
    def due?(every_hours: EVERY_HOURS)
      !BackupRun.where("ran_at > ?", database_now - every_hours.to_f.hours).exists?
    end

    def empty? = false

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

    # bin/backup: a look when it starts and then every look_every seconds,
    # until stop answers true; a backup at each look where one is due. A
    # look that fails is logged and the next one runs on time. The sleeper,
    # stop and the module are parameters, so the loop is tested without
    # waiting.
    def run_loop(folder: FOLDER, keep: KEEP, every_hours: EVERY_HOURS, look_every: LOOK_EVERY, stop: -> { false },
                 sleeper: nil, log: nil, backup: self)
      log ||= method(:log_error)
      sleeper ||= ->(seconds) { pause(seconds, stop) }
      until stop.call
        begin
          backup.run(folder: folder, keep: keep, log: log) if backup.due?(every_hours: every_hours)
        rescue StandardError => error
          log.call("#{LOG} look failed folder=#{folder} error=#{error.class} message=#{error.message.inspect}")
        end
        sleeper.call(look_every) unless stop.call
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

      drop_database(target, spawner: spawner)
      tool!(target, spawner, "createdb", *target.connection_args, "--maintenance-db=#{MAINTENANCE_DATABASE}",
        target.database)
      tool!(target, spawner, "pg_restore", *RESTORE_FLAGS, *target.connection_args, "--dbname", target.database, file)
      connected_to(target) do
        load_tasks
        DbGrants.apply(ActiveRecord::Base.lease_connection)
        verify!(workspace_id)
      end
      target
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
