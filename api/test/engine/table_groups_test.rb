require "test_helper"

# The table of entries while milestone 3 is built (milestone 3 plan HT-6,
# §2.1): the twelve new entries wait in Transitions::Table::PENDING, which
# Table.entry_for, Table.known? and Table.with_entries read and
# Table.include?, Table::COMMANDS and every walk of the table do not; the
# eleven new operations wait in Http::RouteTable::PENDING, out of ROUTES.
# Served and pending are counted together, so these tests hold before and
# after WP7 and WP10 move them. It also pins the first versions of the
# seams other packages finish: their names, arguments and do-nothing
# answers (the hand-over table of plan §4).
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

  def pending = Table.const_defined?(:PENDING) ? Table::PENDING : []

  def pending_groups = Table.const_defined?(:PENDING_GROUPS) ? Table::PENDING_GROUPS : {}

  def pending_operations = RouteTable.const_defined?(:PENDING) ? RouteTable::PENDING : {}

  # --- Transitions::Table --------------------------------------------------------

  test "served and pending together are 48 commands, no name twice, each a registry command with rows" do
    all = Table::COMMANDS + pending
    with_rows = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
      .map { |row| row.fetch("command") }

    assert_equal 48, all.size
    assert_equal all.uniq, all
    all.each do |command|
      assert_includes registry.fetch("commands"), command
      assert_includes with_rows, command
    end
  end

  test "the twelve new commands are served or pending, and each pending one is in the group it moves into" do
    assert_equal NEW_COMMANDS.values.flatten.sort, (NEW_COMMANDS.values.flatten & (Table::COMMANDS + pending)).sort
    assert_equal pending.sort, pending_groups.values.flatten.sort
    pending_groups.each do |group, commands|
      assert_empty commands - NEW_COMMANDS.fetch(group), group
    end
  end

  test "entry_for and known? find a pending name; include? and COMMANDS do not" do
    pending.each do |command|
      assert Table.known?(command), command
      refute Table.include?(command), command
      refute_includes Table::COMMANDS, command
      assert_equal Table.class_name(command), Table.entry_for(command).name
      assert_equal command, Table.entry_for(command).command
      assert_operator Table.entry_for(command), :<, T::Entry
    end
  end

  test "a served name is known, and a later milestone's name is neither known nor found" do
    assert Table.known?("claim")
    assert Table.known?(:claim)
    refute Table.known?("add_rule")
    assert_raises(Table::UnknownCommand) { Table.entry_for("add_rule") }
    assert_raises(Table::UnknownCommand) { Table.with_entries("add_rule" => T::Entry) { flunk "ran" } }
  end

  test "with_entries accepts a pending name" do
    replacement = Class.new(T::Entry)
    Table.with_entries("report_limit" => replacement) do
      assert_equal replacement, Table.entry_for("report_limit")
    end
    assert_equal "Leverage::Transitions::Entries::ReportLimit", Table.entry_for("report_limit").name
  end

  test "a pending timer's entry does nothing; a pending command's entry is not built yet" do
    scenario = Scenario.new
    ctx = scenario.context
    pending.each do |command|
      entry = Table.entry_for(command).new
      if NEW_TIMERS.include?(command)
        entry.perform(ctx)
        assert_nil entry.result, command
      else
        error = assert_raises(NotImplementedError, command) { entry.perform(ctx) }
        assert_match(/not built yet/, error.message)
      end
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
    assert_equal finishing.first.refusal, cases.find { |kase| kase.row == finishing.first.row }.refusal
  end

  test "a served case keeps its refusal as expected_refusal" do
    kase = StateTableCases.for(%w[hold]).find { |candidate| candidate.from == "done" }

    assert_equal kase.refusal, kase.expected_refusal
    refute kase.not_served?
  end

  # --- Http::RouteTable -------------------------------------------------------------

  test "served and pending operations are disjoint, and the eleven are one or the other" do
    assert_empty RouteTable::ROUTES.keys & pending_operations.keys
    assert_equal NEW_OPERATIONS.keys.sort, (NEW_OPERATIONS.keys & (RouteTable::ROUTES.keys + pending_operations.keys)).sort
    NEW_OPERATIONS.each do |operation_id, target|
      assert_equal target, RouteTable::ROUTES[operation_id] || pending_operations[operation_id], operation_id
    end
  end

  test "a pending operation is not served, and its route reads the registry's method and path" do
    routes = RouteTable.routes(pending_operations).index_by(&:operation_id)
    pending_operations.each_key do |operation_id|
      refute RouteTable.serves?(operation_id), operation_id
      operation = registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }
      assert_equal [ operation.fetch("method").downcase, operation.fetch("path").gsub(/\{([a-z]+)\}/, ':\1') ],
        [ routes.fetch(operation_id).verb, routes.fetch(operation_id).path ]
    end
  end

  test "the commands of the eleven operations are the new commands of the table, or a read" do
    commands = NEW_OPERATIONS.keys.flat_map do |operation_id|
      registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }.fetch("commands")
    end
    known = commands.select { |command| Table.known?(command) }

    assert_equal (NEW_COMMANDS.values.flatten - NEW_TIMERS).sort, known.sort
    assert_equal %w[read report_job_limit report_job_signed_out].sort, (commands - known).sort
  end

  # --- The first versions of the seams other packages finish --------------------

  test "Handoff has its four methods with their final arguments, and each does nothing" do
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
    assert_nil handoff.reevaluate(Scenario.new.context)
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
    assert_equal 0, HelperRequest.count
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
