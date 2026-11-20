require "test_helper"
require "open3"
require "tmpdir"

# The daily backup (milestone 3 plan §2.5, HB-1 to HB-4, HB-8): one look
# dumps the database the program is connected to, by name, with the real
# pg_dump of the image, into a folder of its own; the file appears whole
# (written as .partial, then renamed) with mode 0600, one backup_runs row
# names it, and the newest KEEP rows' files are kept. A dump uses a
# connection of its own and sees only committed rows, so these tests
# commit (CommittingTestCase); each starts and ends with no backup_runs
# row in its worker's database.
class BackupTest < CommittingTestCase
  B = Leverage::Backup
  NAME = /\Aleverage-\d{8}T\d{9}Z\.dump\z/

  setup do
    BackupRun.delete_all
    @folder = Dir.mktmpdir("backup-test")
    @calls = []
    @spawner = lambda do |env, argv, **redirects|
      @calls << [ env, argv ]
      Process.spawn(env, *argv, **redirects)
    end
    @lines = []
    @log = ->(line) { @lines << line }
  end

  teardown do
    BackupRun.delete_all
    File.chmod(0o700, @folder) if File.directory?(@folder)
    FileUtils.rm_rf(@folder)
  end

  def config = ActiveRecord::Base.connection_db_config.configuration_hash
  def database_now = ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")

  # The PostgreSQL tools' connection, written here, not taken from the
  # code under test.
  def tool_env = { "PGPASSWORD" => config[:password].to_s }
  def tool_args = [ "--host", config[:host].to_s, "--port", config[:port].to_s, "--username", config[:username].to_s ]

  def tool(*argv)
    out, status = Open3.capture2e(tool_env, *argv)
    assert status.success?, "#{argv.first} failed: #{out}"
    out
  end

  # The name of the database a dump was made from, from its own header.
  def dumped_database(path)
    tool("pg_restore", "--list", path)[/^;\s+dbname: (\S+)$/, 1]
  end

  def dump_calls = @calls.select { |_env, argv| argv.first == "pg_dump" }

  # Runs the block connected to a new, empty database made from
  # db/structure.sql: no workspace, no row.
  def with_scratch_database
    original = ActiveRecord::Base.connection_db_config
    name = "#{original.database}_scratch_#{SecureRandom.hex(3)}"
    tool("createdb", *tool_args, "--maintenance-db=postgres", name)
    tool("psql", *tool_args, "--dbname", name, "--quiet", "--set", "ON_ERROR_STOP=1",
      "--file", Rails.root.join("db/structure.sql").to_s)
    ActiveRecord::Base.establish_connection(original.configuration_hash.merge(database: name))
    yield name
  ensure
    ActiveRecord::Base.establish_connection(original)
    Open3.capture2e(tool_env, "dropdb", *tool_args, "--maintenance-db=postgres", "--if-exists", "--force", name) if name
  end

  def make_row(name, ran_at, bytes: 3)
    File.write(File.join(@folder, name), "abc")
    BackupRun.create!(file_name: name, ran_at: ran_at, bytes: bytes)
  end

  test "one backup of a database with no workspace leaves one dump of mode 0600, no partial file and one row" do
    with_scratch_database do |scratch|
      assert_equal 0, Workspace.count
      run = B.run!(folder: @folder, keep: 14, spawner: @spawner)

      assert_kind_of BackupRun, run
      assert_match NAME, run.file_name
      assert_equal [ run.file_name ], Dir.children(@folder)
      path = File.join(@folder, run.file_name)
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal File.size(path), run.bytes
      assert_equal 1, BackupRun.count
      assert_equal scratch, dumped_database(path)
    end
    assert_equal 0, BackupRun.count, "the row went into the database that was dumped"
  end

  test "it dumps the database it is connected to, by name, never the one named after the user" do
    database = ActiveRecord::Base.connection_db_config.database
    refute_equal config[:username], database
    run = B.run!(folder: @folder, keep: 14, spawner: @spawner)

    assert_equal 1, dump_calls.size
    _env, argv = dump_calls.first
    assert_equal database, argv[argv.index("--dbname") + 1]
    %w[--format=custom --no-owner --no-privileges].each { |flag| assert_includes argv, flag }
    path = File.join(@folder, run.file_name)
    assert_equal database, dumped_database(path)
    data = tool("pg_restore", "--data-only", "--table=workspaces", "--file=-", path)
    assert_includes data, scenario.workspace_id, "the dump holds this test's committed workspace"
  end

  test "no argument of the child holds the password; the child reads it from PGPASSWORD" do
    password = config[:password].to_s
    refute_empty password
    B.run!(folder: @folder, keep: 14, spawner: @spawner)

    env, argv = dump_calls.first
    assert argv
    argv.each { |argument| refute_includes argument.to_s, password }
    refute(argv.any? { |argument| argument.to_s.include?("://") }, "no URL in the arguments")
    assert_equal password, env["PGPASSWORD"]
  end

  test "a dump into a folder it cannot write leaves no file and no row, logs the folder, and raises nothing from the loop" do
    scenario
    File.chmod(0o500, @folder)
    refute File.writable?(@folder), "the test needs a folder this user cannot write"

    assert_nil B.run(folder: @folder, keep: 14, spawner: @spawner, log: @log)
    assert_empty Dir.children(@folder)
    assert_equal 0, BackupRun.count
    assert_equal 1, @lines.size
    assert_includes @lines.first, @folder

    assert_raises(B::Failed) { B.run!(folder: @folder, keep: 14, spawner: @spawner) }

    sleeps = []
    B.run_loop(folder: @folder, keep: 14, every_hours: 24, stop: -> { sleeps.any? },
      sleeper: ->(seconds) { sleeps << seconds }, log: @log)
    assert_equal [ B::LOOK_EVERY ], sleeps
    assert_empty Dir.children(@folder)
    assert_equal 0, BackupRun.count
  end

  test "a pg_dump that fails removes its partial file and writes no row" do
    target = B::Target.current.with(database: "no_such_database_#{SecureRandom.hex(3)}")

    assert_nil B.run(folder: @folder, keep: 14, target: target, spawner: @spawner, log: @log)
    assert_equal 1, dump_calls.size, "pg_dump ran"
    assert_empty Dir.children(@folder)
    assert_equal 0, BackupRun.count
    assert_equal 1, @lines.size
    assert_includes @lines.first, @folder
  end

  test "pruning keeps the newest rows' files, removes the oldest two with their rows, and touches no other file" do
    now = database_now
    rows = (1..16).map { |hours| make_row("leverage-2026010#{hours / 10}T#{format("%02d", hours)}0000000Z.dump", now - hours.hours) }
    stray = "leverage-19990101T000000000Z.dump"
    File.write(File.join(@folder, stray), "not named by any row")
    File.write(File.join(@folder, "notes.txt"), "the owner's own file")

    B.prune(@folder, keep: 14)

    oldest = rows.last(2)
    kept = rows.first(14)
    oldest.each do |row|
      refute File.exist?(File.join(@folder, row.file_name)), row.file_name
      refute BackupRun.exists?(row.id), row.file_name
    end
    kept.each { |row| assert File.exist?(File.join(@folder, row.file_name)), row.file_name }
    assert_equal kept.map(&:id).sort, BackupRun.pluck(:id).sort
    assert File.exist?(File.join(@folder, stray))
    assert File.exist?(File.join(@folder, "notes.txt"))
  end

  test "a backup prunes: with the keep reached, its dump replaces the oldest" do
    now = database_now
    rows = (1..3).map { |days| make_row("leverage-2026010#{days}T000000000Z.dump", now - days.days) }

    run = B.run!(folder: @folder, keep: 3, spawner: @spawner)

    assert_equal [ run.id, rows[0].id, rows[1].id ].sort, BackupRun.pluck(:id).sort
    refute File.exist?(File.join(@folder, rows[2].file_name))
    assert_equal [ rows[0].file_name, rows[1].file_name, run.file_name ].sort, Dir.children(@folder).sort
  end

  test "a backup is due with no row, not within the hours of the newest row, and due again after them" do
    scenario
    assert B.due?(every_hours: 24)

    row = BackupRun.create!(file_name: "leverage-20260101T000000000Z.dump", ran_at: database_now - 23.hours, bytes: 1)
    refute B.due?(every_hours: 24)

    row.update!(ran_at: database_now - 25.hours)
    assert B.due?(every_hours: 24)
  end

  # Review: after the volume is lost, the first look finds a new, empty
  # database; a dump of it would become the newest file in the folder.
  test "no backup is due while the database holds no workspace, whatever the rows say (review)" do
    with_scratch_database do
      assert_equal 0, Workspace.count
      refute B.due?(every_hours: 24)
      assert B.empty?
    end
    scenario
    refute B.empty?
  end

  test "while the database holds no workspace the loop makes no dump and looks again within a minute (review)" do
    with_scratch_database do
      sleeps = []
      B.run_loop(folder: @folder, keep: 14, every_hours: 24, stop: -> { sleeps.any? },
        sleeper: ->(seconds) { sleeps << seconds }, log: @log)

      assert_equal [ B::EMPTY_LOOK_EVERY ], sleeps
      assert_operator B::EMPTY_LOOK_EVERY, :<=, 60
      assert_empty Dir.children(@folder)
      assert_equal 0, BackupRun.count
      assert_empty @lines
    end
  end

  # A stand-in for the module, so the loop is tested without waiting.
  class Recorder
    attr_reader :looks, :runs

    def initialize(due)
      @due = due
      @looks = 0
      @runs = []
    end

    def due?(every_hours:)
      @looks += 1
      raise "the database is not there yet" if @due[@looks - 1] == :raise

      @due[@looks - 1]
    end

    def run(folder:, keep:, log:)
      @runs << [ folder, keep ]
    end

    def empty? = false
  end

  test "the loop looks when it starts and then every 15 minutes, backs up only when due, and survives an error" do
    recorder = Recorder.new([ true, :raise, false, true ])
    sleeps = []
    B.run_loop(folder: @folder, keep: 5, every_hours: 24, stop: -> { sleeps.size >= 4 },
      sleeper: ->(seconds) { sleeps << seconds }, log: @log, backup: recorder)

    assert_equal 15 * 60, B::LOOK_EVERY
    assert_equal [ 900, 900, 900, 900 ], sleeps
    assert_equal 4, recorder.looks
    assert_equal [ [ @folder, 5 ], [ @folder, 5 ] ], recorder.runs
    assert_equal 1, @lines.size, "the error is logged once"
  end
end
