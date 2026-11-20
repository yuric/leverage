require "test_helper"
require "open3"
require "tmpdir"
require_relative "../support/trace_runner"
require_relative "../support/walk"

# The restore (milestone 3 plan §2.5, HB-5, HB-6; PRD L921 "a restore
# passes the replay test"). Trace 09's log (milestone 2's commands) is
# committed into the parallel worker's own database, which is dumped by
# the name connection_db_config gives and restored into a scratch database
# named after it that does not exist beforehand: there the replay and the
# audit pass, the events are the same rows, and the application's role has
# its rights again. The dump carries no grant and no owner. A restore over
# a database that holds a log changes nothing without --replace.
#
# The restore's own check is leverage:verify_log, whose audit finds every
# event no command wrote: a trace's setup events are such events (the
# golden test audits a trace after its setup, after_seq). So the restore
# here checks a walk's workspace, whose whole log the engine wrote, and
# the test checks trace 09's after its setup itself.
class BackupRestoreTest < CommittingTestCase
  B = Leverage::Backup

  setup do
    BackupRun.delete_all
    @folder = Dir.mktmpdir("backup-restore-test")
    @original = ActiveRecord::Base.connection_db_config
    @scratch = "#{@original.database}_restored_#{SecureRandom.hex(3)}"
  end

  teardown do
    ActiveRecord::Base.establish_connection(@original)
    Open3.capture2e(tool_env, "dropdb", *tool_args, "--maintenance-db=postgres", "--if-exists", "--force", @scratch)
    BackupRun.delete_all
    FileUtils.rm_rf(@folder)
  end

  def config = @original.configuration_hash
  def tool_env = { "PGPASSWORD" => config[:password].to_s }
  def tool_args = [ "--host", config[:host].to_s, "--port", config[:port].to_s, "--username", config[:username].to_s ]

  def database_exists?(name)
    ActiveRecord::Base.lease_connection.select_value(
      ActiveRecord::Base.sanitize_sql([ "SELECT count(*) FROM pg_database WHERE datname = ?", name ])
    ).to_i == 1
  end

  def on_database(name)
    ActiveRecord::Base.establish_connection(config.merge(database: name))
    yield
  ensure
    ActiveRecord::Base.establish_connection(@original)
  end

  def events_of(workspace_id)
    ActiveRecord::Base.lease_connection.select_all(
      ActiveRecord::Base.sanitize_sql([ "SELECT * FROM events WHERE workspace_id = ? ORDER BY seq", workspace_id ])
    ).to_a
  end

  def log_figures
    ActiveRecord::Base.lease_connection.select_rows("SELECT count(*), max(seq), max(created_at) FROM events").first
  end

  def privilege?(table, right)
    ActiveRecord::Base.lease_connection.select_value("SELECT has_table_privilege('leverage_app', 'public.#{table}', '#{right}')")
  end

  # bin/restore as the maintainer runs it, pointed at one database: the
  # URL's database wins over config/database.yml's name.
  def bin_restore(database, *args)
    url = "postgres://#{config[:username]}:#{config[:password]}@#{config[:host]}:#{config[:port]}/#{database}"
    Open3.capture3({ "DATABASE_URL" => url, "RAILS_ENV" => "test" }, "bin/restore", *args, chdir: Rails.root.to_s)
  end

  def target(name) = B::Target.current.with(database: name)

  test "a dump of trace 09's log restores into a new database where the replay and the audit pass and the rows are the same" do
    runner = TraceRunner.new("09-core-loop-no-rules").run
    assert_empty runner.failures, runner.failures.join("\n")
    workspace_id = runner.workspace_id
    before = events_of(workspace_id)
    assert_operator before.size, :>, runner.setup_seq
    walk = Walk.new(seed: 909).run
    walked = events_of(walk.workspace_id)

    run = B.run!(folder: @folder, keep: 14)
    path = File.join(@folder, run.file_name)
    refute database_exists?(@scratch), "the scratch database does not exist beforehand"

    out, = capture_io { B.restore(path, target: target(@scratch), workspace_id: walk.workspace_id) }

    assert_match(/workspace #{walk.workspace_id}: #{walked.size} events, replay ok, audit ok/, out)
    assert database_exists?(@scratch)
    assert_equal @original, ActiveRecord::Base.connection_db_config, "the restore gives the connection back"
    on_database(@scratch) do
      assert_equal before, events_of(workspace_id)
      assert_equal walked, events_of(walk.workspace_id)
      assert_empty Leverage::Replay.diff(workspace_id)
      assert_empty Leverage::LogAudit.call(workspace_id, after_seq: runner.setup_seq)
      assert privilege?("events", "SELECT")
      assert privilege?("events", "INSERT")
      refute privilege?("events", "UPDATE")
      assert privilege?("tasks", "UPDATE")
      assert privilege?("backup_runs", "SELECT")
      refute privilege?("backup_runs", "INSERT")
    end

    # The archive holds no grant at all. It does keep each object's owner
    # (pg_dump ignores --no-owner for an archive format), so the restore
    # drops it: what the restore's own flags write has no OWNER TO either.
    sql, status = Open3.capture2e(tool_env, "pg_restore", "--file=-", path)
    assert status.success?, sql
    assert_includes sql, "CREATE TABLE public.events"
    refute_match(/\bGRANT\b/, sql)
    refute_match(/\bREVOKE\b/, sql)
    restored, status = Open3.capture2e(tool_env, "pg_restore", *B::RESTORE_FLAGS, "--file=-", path)
    assert status.success?, restored
    assert_includes restored, "CREATE TABLE public.events"
    refute_match(/OWNER TO/, restored)
    refute_match(/\bGRANT\b/, restored)
  end

  test "bin/restore over a database that holds events exits non-zero without --replace and changes nothing" do
    scenario.task(state: "backlog")
    run = B.run!(folder: @folder, keep: 14)
    path = File.join(@folder, run.file_name)
    before = log_figures
    assert_operator before.first, :>, 0

    _out, err, status = bin_restore(@original.database, path)

    refute status.success?, "bin/restore replaced a log without --replace"
    assert_match(/events/, err)
    assert_match(/--replace/, err)
    assert database_exists?(@original.database)
    assert_equal before, log_figures
    assert_raises(B::Refused) { B.restore(path) }
    assert_equal before, log_figures
  end

  test "a restore over a restored log needs --replace, and with it replaces the log" do
    walk = Walk.new(seed: 32).run
    task = Task.where(workspace_id: walk.workspace_id).first
    assert task, walk.to_s
    run = B.run!(folder: @folder, keep: 14)
    path = File.join(@folder, run.file_name)
    capture_io { B.restore(path, target: target(@scratch), workspace_id: walk.workspace_id) }

    _out, err, status = bin_restore(@scratch, path)
    refute status.success?
    assert_match(/--replace/, err)
    assert_raises(B::Refused) { B.restore(path, target: target(@scratch), workspace_id: walk.workspace_id) }

    on_database(@scratch) { Task.where(id: task.id).update_all(title: "Changed after the dump") }
    capture_io { B.restore(path, target: target(@scratch), replace: true, workspace_id: walk.workspace_id) }
    on_database(@scratch) { assert_equal task.title, Task.find(task.id).title }
  end

  test "bin/restore with no file, or a file that is not there, exits non-zero" do
    _out, _err, status = bin_restore(@scratch)
    refute status.success?
    _out, err, status = bin_restore(@scratch, File.join(@folder, "leverage-missing.dump"))
    refute status.success?
    assert_match(/no dump/i, err)
    refute database_exists?(@scratch)
  end
end
