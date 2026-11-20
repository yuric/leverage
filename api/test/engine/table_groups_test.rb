require "test_helper"

# The table of entries after milestone 3 (milestone 3 plan HT-6, §2.1):
# the twelve new entries waited in Transitions::Table::PENDING, and the
# eleven new operations in Http::RouteTable::PENDING, while the packages
# that wrote them worked; WP7 moved the operations into ROUTES and WP10 the
# entries into their groups, and both PENDING lists are gone. It also pins
# the seams other packages finished: their names, arguments and answers
# (the hand-over table of plan §4).
class TableGroupsTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  Table = T::Table
  RouteTable = Leverage::Http::RouteTable

  NEW_COMMANDS = {
    "HANDOFF" => %w[report_limit report_signed_out sign_in_again],
    "TIMERS" => %w[credential_hold_release seat_run_placement],
    "OWNER_CONTROLS" => %w[promote edit_contract hold resume pause_seat resume_seat change_seat]
  }.freeze
  NEW_TIMERS = %w[credential_hold_release seat_run_placement].freeze

  NEW_OPERATIONS = {
    "report_limit" => "v1/helper/credentials#limit_reached",
    "report_signed_out" => "v1/helper/credentials#signed_out",
    "sign_in_again" => "v1/owner/credentials#sign_in",
    "list_inbox" => "v1/owner/inbox#index",
    "promote_task" => "v1/owner/tasks#promote",
    "edit_contract" => "v1/owner/tasks#contract",
    "hold_task" => "v1/owner/tasks#hold",
    "resume_task" => "v1/owner/tasks#resume",
    "pause_seat" => "v1/owner/seats#pause",
    "resume_seat" => "v1/owner/seats#resume",
    "change_seat" => "v1/owner/seats#change"
  }.freeze

  def registry = Leverage::Contract.registry

  # --- Transitions::Table --------------------------------------------------------

  test "neither table keeps a PENDING list, and Table answers only include? (HT-6)" do
    refute Table.const_defined?(:PENDING, false), "Transitions::Table::PENDING is gone"
    refute Table.const_defined?(:PENDING_GROUPS, false), "Transitions::Table::PENDING_GROUPS is gone"
    refute RouteTable.const_defined?(:PENDING, false), "Http::RouteTable::PENDING is gone"
    refute Table.respond_to?(:known?), "known? answered for pending names; include? is the one question again"
  end

  test "the table is 48 commands, no name twice, each a registry command with rows" do
    all = Table::COMMANDS
    with_rows = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
      .map { |row| row.fetch("command") }

    assert_equal 48, all.size
    assert_equal all.uniq, all
    all.each do |command|
      assert_includes registry.fetch("commands"), command
      assert_includes with_rows, command
    end
  end

  test "the twelve new commands are each in the group the plan names" do
    assert_equal NEW_COMMANDS.fetch("HANDOFF"), Table::HANDOFF
    assert_equal NEW_COMMANDS.fetch("OWNER_CONTROLS"), Table::OWNER_CONTROLS
    assert_equal NEW_TIMERS, Table::TIMERS.last(2)
    NEW_COMMANDS.each do |group, commands|
      assert_empty commands - Table.const_get(group), group
    end
  end

  test "entry_for finds each new command, which include? and COMMANDS answer for" do
    NEW_COMMANDS.values.flatten.each do |command|
      assert Table.include?(command), command
      assert_includes Table::COMMANDS, command
      assert_equal Table.class_name(command), Table.entry_for(command).name
      assert_equal command, Table.entry_for(command).command
      assert_operator Table.entry_for(command), :<, T::Entry
    end
  end

  test "a served name is included, and a later milestone's name is neither included nor found" do
    assert Table.include?("claim")
    assert Table.include?(:claim)
    refute Table.include?("add_rule")
    assert_raises(Table::UnknownCommand) { Table.entry_for("add_rule") }
    assert_raises(Table::UnknownCommand) { Table.with_entries("add_rule" => T::Entry) { flunk "ran" } }
  end

  test "with_entries accepts a new name" do
    replacement = Class.new(T::Entry)
    Table.with_entries("report_limit" => replacement) do
      assert_equal replacement, Table.entry_for("report_limit")
    end
    assert_equal "Leverage::Transitions::Entries::ReportLimit", Table.entry_for("report_limit").name
  end

  # WP3, WP5 and WP6 built the twelve entries (their notes); WP1's first
  # versions are gone, so this pins that none is left a stub, and that the
  # two timers write nothing in a workspace where nothing is due.
  test "no new entry is a stub; a new timer writes nothing when nothing is due" do
    ctx = Scenario.new.context(request: T::Request.new(command: "credential_hold_release",
      workspace_id: nil, caller_kind: nil, caller_id: nil, key: nil, request_hash: nil, params: {}))
    NEW_COMMANDS.values.flatten.each do |command|
      source = File.read(Table.entry_for(command).instance_method(:perform).source_location.first)
      refute_match(/NotImplementedError/, source, command)
      next unless NEW_TIMERS.include?(command)

      entry = Table.entry_for(command).new
      entry.load(ctx)
      entry.perform(ctx)
    end
    assert_empty ctx.events
  end

  # --- StateTableCases --------------------------------------------------------------

  test "every case of a row from Finishing is marked not served (HS-3), and no other" do
    cases = StateTableCases.for(NEW_COMMANDS.values.flatten)
    finishing = cases.select { |kase| kase.from == "finishing" && !kase.invalid_state? }

    assert_operator finishing.size, :>, 0
    finishing.each { |kase| assert kase.not_served?, kase.name }
    (cases - finishing).each { |kase| refute kase.not_served?, kase.name }
    assert_equal "invalid_state", finishing.first.expected_refusal
    assert_nil finishing.first.refusal, "the row itself moves the task; HS-3 is what refuses it"
  end

  test "a served case keeps its refusal as expected_refusal" do
    kase = StateTableCases.for(%w[hold]).find { |candidate| candidate.from == "done" }

    assert_equal kase.refusal, kase.expected_refusal
    refute kase.not_served?
  end

  # --- Http::RouteTable -------------------------------------------------------------

  test "the eleven new operations are served, each by its controller and action" do
    NEW_OPERATIONS.each do |operation_id, target|
      assert RouteTable.serves?(operation_id), operation_id
      assert_equal target, RouteTable::ROUTES[operation_id], operation_id
    end
  end

  test "the commands of the eleven operations are the new commands of the table, or a read" do
    commands = NEW_OPERATIONS.keys.flat_map do |operation_id|
      registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }.fetch("commands")
    end
    known = commands.select { |command| Table.include?(command) }

    assert_equal (NEW_COMMANDS.values.flatten - NEW_TIMERS).sort, known.sort
    assert_equal %w[read report_job_limit report_job_signed_out].sort, (commands - known).sort
  end

  # --- The first versions of the seams other packages finish --------------------

  # WP3 built them; reevaluate answers the events it wrote (none here).
  test "Handoff has its four methods with their final arguments, and reevaluate writes nothing in an empty workspace" do
    handoff = Leverage::Handoff
    expected = {
      interrupt: [ [ :req, :ctx ], [ :keyreq, :credential ], [ :keyreq, :seat ], [ :keyreq, :kind ], [ :key, :task ],
                   [ :key, :review ], [ :key, :window ], [ :key, :reset_at ], [ :key, :observed_at ] ],
      continue_or_hold: [ [ :req, :ctx ], [ :keyreq, :seat ], [ :keyreq, :stopped ], [ :keyreq, :cause ], [ :key, :task ],
                          [ :key, :review ] ],
      reevaluate: [ [ :req, :ctx ], [ :key, :tasks ], [ :key, :cause ], [ :key, :verified ], [ :key, :signed_out ],
                    [ :key, :choice ] ],
      switch: [ [ :req, :ctx ], [ :keyreq, :seat ], [ :keyreq, :to ], [ :keyreq, :from ], [ :keyreq, :cause ],
                [ :key, :task ], [ :key, :review ] ]
    }
    expected.each { |name, parameters| assert_equal parameters, handoff.method(name).parameters, name }
    assert_equal [], handoff.reevaluate(Scenario.new.context)
  end

  test "SeatRuns has placement, ensure_run_on and ended_by_interruption; placement answers the seat's own credential" do
    scenario = Scenario.new
    credential = scenario.credential
    seat = scenario.seat(credential: credential)
    placement = Leverage::SeatRuns.placement(seat)

    assert_equal [ credential.id, nil ], [ placement.credential&.id, placement.work ]
    assert_nil Leverage::SeatRuns.placement(scenario.seat(provider: "claude")).credential
    assert_equal [ [ :req, :ctx ], [ :req, :seat ], [ :req, :credential ], [ :req, :work ] ],
      Leverage::SeatRuns.method(:ensure_run_on).parameters
    assert_nil Leverage::SeatRuns.ensure_run_on(scenario.context, seat, credential, nil)
    assert_equal [ [ :req, :seat ], [ :req, :reason ] ], Leverage::SeatRuns.method(:ended_by_interruption).parameters
    assert_equal 0, HelperRequest.where(workspace_id: scenario.workspace_id).count
  end

  test "Reads::RecoveryTimes answers an empty list, for a task or for the workspace" do
    scenario = Scenario.new
    task = scenario.task(state: "working")

    assert_equal [], Leverage::Reads::RecoveryTimes.call(scenario.workspace_id)
    assert_equal [], Leverage::Reads::RecoveryTimes.call(scenario.workspace_id, task_id: task.id)
  end

  test "BackupRun is the model of backup_runs" do
    assert_equal "backup_runs", BackupRun.table_name
  end
end
