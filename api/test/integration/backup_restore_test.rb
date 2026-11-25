require "test_helper"
require "open3"
require "tmpdir"
require_relative "../support/trace_runner"
require_relative "../support/walk"
require_relative "../support/old_step_tracker"

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
  include OldStepTracker

  B = Leverage::Backup
  T = Leverage::Transitions

  setup do
    BackupRun.delete_all
    @started = ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
    @folder = Dir.mktmpdir("backup-restore-test")
    @original = ActiveRecord::Base.connection_db_config
    @scratch = "#{@original.database}_restored_#{SecureRandom.hex(3)}"
  end

  teardown do
    ActiveRecord::Base.establish_connection(@original)
    [ @scratch, *restoring_databases ].uniq.each do |name|
      Open3.capture2e(tool_env, "dropdb", *tool_args, "--maintenance-db=postgres", "--if-exists", "--force", name)
    end
    BackupRun.delete_all
    # A walk's owner lets checks through once (milestone 4 plan RT-3), and
    # rule_checks.overridden_by_user_id references users, which the owner
    # tests of this worker delete (WP11's request 5): this test's commits
    # leave no override behind.
    RuleCheck.where.not(overridden_by_user_id: nil).where(created_at: @started..).update_all(overridden_by_user_id: nil)
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

  # Trace 09 committed into the worker's database: its rows stay (events
  # cannot be deleted), so they take ids of their own and never meet the
  # ids a later trace run in this database binds.
  def committed_trace = TraceRunner.new("09-core-loop-no-rules", namespace: SecureRandom.uuid).run

  test "a dump of trace 09's log restores into a new database where the replay and the audit pass and the rows are the same" do
    runner = committed_trace
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

  test "the trace this test commits leaves no id that a later trace run in the same database meets" do
    committed = committed_trace
    assert_empty committed.failures, committed.failures.join("\n")

    ActiveRecord::Base.transaction do
      later = TraceRunner.new("09-core-loop-no-rules").run
      assert_empty later.failures, later.failures.join("\n")
      refute_equal committed.workspace_id, later.workspace_id
      raise ActiveRecord::Rollback
    end
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

  # A walk's workspace (its whole log is the engine's) with every rule off,
  # in which a promoted Imaginarium idea reached its first working step
  # while the step tracker read criteria the old way: the rows a database
  # held before the tracker read task.created's criteria (FR-039).
  def workspace_with_old_idea_steps
    walk = Walk.new(seed: 77, steps: 0).run
    id = walk.workspace_id
    owner = walk.scenario.owner
    builder = Seat.where(workspace_id: id, role: "builder", credential_id: nil).order(:created_at, :id).first
    calls = 0
    apply = lambda do |name, caller, params|
      kind = caller.is_a?(User) ? "owner" : "seat"
      outcome = T.apply(T::Request.new(command: name, workspace_id: id, caller_kind: kind, caller_id: caller.id,
        key: "old-steps-#{calls += 1}", request_hash: Digest::SHA256.hexdigest(JSON.generate(params)), params: params))
      assert outcome.completed?, "#{name} was #{outcome.outcome}"
      outcome
    end
    Rule.where(workspace_id: id, enabled: true).each { |rule| apply.call("disable_rule", owner, "id" => rule.id) }
    assert Leverage::Timers.apply_workspace(id, "install_imaginarium_project", at: Time.current).completed?
    criteria = [ { "text" => "It opens on the Mac.", "kind" => "build" }, { "text" => "Tasks are kept.", "kind" => "build" },
                 { "text" => "A second agent reviews the work", "kind" => "review" } ]
    with_the_old_step_tracker do
      task = Task.find(apply.call("add_task", owner, "title" => "Pocket to-do", "details" => "A made-up checklist.",
        "state" => "ideas", "criteria" => criteria,
        "imaginarium" => { "entry_id" => "pocket-to-do", "catalog_version" => 1 }).result.fetch("task_id"))
      apply.call("promote", owner, "id" => task.id)
      apply.call("complete_contract", owner, "id" => task.id, "title" => "Pocket to-do",
        "details" => "A made-up checklist.", "criteria" => criteria, "actions" => [], "minimum_strength_rank" => nil,
        "budget_cap" => nil, "work_reference" => nil)
      apply.call("claim", builder, {})
      apply.call("acknowledge_briefing", builder, "id" => task.id,
        "briefing_hash" => Leverage::Briefing.hash_for(task.reload, seat: builder))
    end
    id
  end

  def without_the_step_repair_migration
    version = ActiveRecord::Base.lease_connection.quote(Leverage::StepRepair::MIGRATION)
    ActiveRecord::Base.lease_connection.execute("DELETE FROM schema_migrations WHERE version = #{version}")
    yield
  ensure
    ActiveRecord::Base.establish_connection(@original)
    ActiveRecord::Base.lease_connection.execute(
      "INSERT INTO schema_migrations (version) VALUES (#{version}) ON CONFLICT DO NOTHING"
    )
  end

  # The steps of a promoted Imaginarium idea stored before the tracker read
  # task.created's criteria fail the replay test. A dump made before the
  # migration that repairs them is repaired in the restored copy, before
  # the replay test; a dump made after it is held to the replay test as it
  # is.
  test "a dump made before the step repair is repaired in the restored copy, and a later one is not" do
    workspace_id = workspace_with_old_idea_steps
    refute_empty Leverage::Replay.diff(workspace_id), "the old rows differ from the log's"
    later = File.join(@folder, B.run!(folder: @folder, keep: 14).file_name)
    earlier = without_the_step_repair_migration { File.join(@folder, B.run!(folder: @folder, keep: 14).file_name) }

    error = nil
    capture_io { error = assert_raises(B::Failed) { B.restore(later, target: target(@scratch), workspace_id: workspace_id) } }
    assert_match(/replay test/, error.message)
    refute database_exists?(@scratch)

    out, = capture_io { B.restore(earlier, target: target(@scratch), workspace_id: workspace_id) }

    assert_match(/workspace #{workspace_id}: \d+ events, replay ok, audit ok/, out)
    on_database(@scratch) { assert_empty Leverage::Replay.diff(workspace_id) }
  ensure
    # This worker's database keeps the workspace: its rows are repaired, so
    # that no later test finds them.
    Leverage::StepRepair.call
  end

  # The shortest beginning of a dump whose list pg_restore still reads:
  # the dump cut just after its table of contents, with none of its data.
  def list_only_length(path)
    bytes = File.binread(path)
    low = 0
    high = bytes.bytesize
    probe = File.join(@folder, "probe.dump")
    while low < high
      middle = (low + high) / 2
      File.binwrite(probe, bytes.byteslice(0, middle))
      _out, status = Open3.capture2e(tool_env, "pg_restore", "--list", probe)
      status.success? ? high = middle : low = middle + 1
    end
    File.delete(probe)
    low
  end

  def restoring_databases
    ActiveRecord::Base.lease_connection.select_values(
      ActiveRecord::Base.sanitize_sql([ "SELECT datname FROM pg_database WHERE datname LIKE ?", "#{@scratch}%" ])
    )
  end

  # Review: --replace dropped the database before pg_restore had read the
  # dump, so a dump that could not be restored left no database at all.
  test "a restore with --replace from a dump that cannot be restored leaves the database as it was (review)" do
    scenario.task(state: "backlog")
    run = B.run!(folder: @folder, keep: 14)
    path = File.join(@folder, run.file_name)
    # The database the restore would replace: made from the schema, with
    # one task of its own.
    Open3.capture2e(tool_env, "createdb", *tool_args, "--maintenance-db=postgres", @scratch).then do |out, status|
      assert status.success?, out
    end
    out, status = Open3.capture2e(tool_env, "psql", *tool_args, "--dbname", @scratch, "--quiet", "--set",
      "ON_ERROR_STOP=1", "--file", Rails.root.join("db/structure.sql").to_s)
    assert status.success?, out
    task = on_database(@scratch) { Scenario.new.task(state: "backlog", title: "Changed after the dump") }

    garbage = File.join(@folder, "leverage-garbage.dump")
    File.write(garbage, "not a dump at all")
    truncated = File.join(@folder, "leverage-truncated.dump")
    File.binwrite(truncated, File.binread(path).byteslice(0, list_only_length(path)))
    _list, listed = Open3.capture2e(tool_env, "pg_restore", "--list", truncated)
    assert listed.success?, "the truncated dump keeps its list, so only the restore itself can find the loss"

    [ garbage, truncated ].each do |bad|
      assert_raises(B::Failed, bad) do
        capture_io { B.restore(bad, target: target(@scratch), replace: true) }
      end
      assert database_exists?(@scratch), "#{bad}: the database is still there"
      on_database(@scratch) { assert_equal "Changed after the dump", Task.find(task.id).title, bad }
      assert_equal [ @scratch ], restoring_databases, "#{bad}: no database is left behind"
    end
  end

  # The schema with one task of its own, at @scratch: the database a
  # restore with --replace would replace.
  def scratch_with_a_task
    Open3.capture2e(tool_env, "createdb", *tool_args, "--maintenance-db=postgres", @scratch).then do |out, status|
      assert status.success?, out
    end
    out, status = Open3.capture2e(tool_env, "psql", *tool_args, "--dbname", @scratch, "--quiet", "--set",
      "ON_ERROR_STOP=1", "--file", Rails.root.join("db/structure.sql").to_s)
    assert status.success?, out
    on_database(@scratch) { Scenario.new.task(state: "backlog", title: "Changed after the dump") }
  end

  # Second review: only a Failed dropped the staging database, so an error
  # of another kind in the steps run on it (the grants' SQL, the
  # connection) left it behind.
  test "a restore whose grants raise an ActiveRecord error removes the staging database and raises Failed (second review)" do
    run = B.run!(folder: @folder, keep: 14)
    path = File.join(@folder, run.file_name)
    B.load_tasks
    original = DbGrants.method(:apply)
    DbGrants.define_singleton_method(:apply) do |*|
      raise ActiveRecord::StatementInvalid, "made-up failure of the grants"
    end
    error = begin
      assert_raises(B::Failed) { capture_io { B.restore(path, target: target(@scratch)) } }
    ensure
      DbGrants.define_singleton_method(:apply, original)
    end
    assert_match(/StatementInvalid/, error.message)
    assert_empty restoring_databases, "no staging database is left behind"
    assert_equal @original, ActiveRecord::Base.connection_db_config, "the restore gives the connection back"
  end

  # Second review: a failed drop of the database being replaced left the
  # staging database behind, unnamed in the message.
  test "a restore with --replace whose drop of the database fails keeps the database and removes the staging one (second review)" do
    walk = Walk.new(seed: 77).run
    run = B.run!(folder: @folder, keep: 14)
    path = File.join(@folder, run.file_name)
    task = scratch_with_a_task
    scratch = @scratch
    spawner = lambda do |env, argv, **redirects|
      if argv.first == "dropdb" && argv.last == scratch
        argv = [ "sh", "-c", "echo 'dropdb: made-up failure' >&2; exit 1" ]
      end
      B::SPAWN.call(env, argv, **redirects)
    end

    error = assert_raises(B::Failed) do
      capture_io do
        B.restore(path, target: target(@scratch), replace: true, workspace_id: walk.workspace_id, spawner: spawner)
      end
    end
    assert_equal [ @scratch ], restoring_databases, "the staging database is removed"
    assert_match(/made-up failure/, error.message)
    assert_includes error.message, @scratch
    on_database(@scratch) { assert_equal "Changed after the dump", Task.find(task.id).title }
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
