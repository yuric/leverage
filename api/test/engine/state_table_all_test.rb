require "test_helper"
require_relative "state_table_test"
require_relative "state_table_timers_test"
require_relative "state_table_sign_in_test"
require_relative "state_table_accounts_test"
require_relative "state_table_handoff_test"
require_relative "state_table_owner_controls_test"

# Test 3 (PRD L836) over the whole of Transitions::Table (milestone 2 plan
# EN-2, WP17; milestone 3 plan HT-2, HS-3). Each state-table test class
# runs one case per state_machine.json row or invalid_state pair for its
# commands; this file proves that together they leave nothing out:
#
# - the six groups are the whole Table of 48, each command in exactly one;
# - the six test classes cover the Table, each command in exactly one;
# - the commands the served operations run (Http::RouteTable, the
#   registry's commands of each operation) are exactly the Table's commands
#   but the timers;
# - every row of every command in the Table is the row of some case, and
#   every case is defined as a test by its class;
# - the only cases that do not run their row are the rows from Finishing,
#   which no command reaches before milestone 5 (HS-3, SC-3).
class StateTableAllTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  TABLE_GROUPS = %i[TASK_LOOP TIMERS SIGN_IN ACCOUNTS HANDOFF OWNER_CONTROLS].freeze

  CLASSES = {
    StateTableTest => T::Table::TASK_LOOP,
    StateTableTimersTest => StateTableTimersTest::COMMANDS,
    StateTableSignInTest => T::Table::SIGN_IN,
    StateTableAccountsTest => T::Table::ACCOUNTS + StateTableAccountsTest::HANDOFF_ACCOUNTS,
    StateTableHandoffTest => StateTableHandoffTest::COMMANDS,
    StateTableOwnerControlsTest => StateTableOwnerControlsTest::COMMANDS
  }.freeze

  test "the six groups are the whole Table of 48, each command in exactly one" do
    commands = TABLE_GROUPS.flat_map { |group| T::Table.const_get(group) }
    assert_equal commands.uniq, commands, "a command is in two groups"
    assert_equal T::Table::COMMANDS.sort, commands.sort
    assert_equal 48, commands.size
  end

  test "the six state-table test classes cover the Table, each command in exactly one" do
    commands = CLASSES.values.flatten
    assert_equal commands.uniq, commands, "a command is walked by two classes"
    assert_equal T::Table::COMMANDS.sort, commands.sort
  end

  test "the commands the served operations run are the Table's commands but the timers" do
    served = Leverage::Http::RouteTable::ROUTES.keys.flat_map do |operation_id|
      Leverage::Contract.registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }
        .fetch("commands")
    end
    # read is a read; the two job reports are milestone 4's (HE-33).
    served = (served - %w[read report_job_limit report_job_signed_out]).uniq
    assert_equal (T::Table::COMMANDS - T::Table::TIMERS).sort, served.sort
  end

  test "every state_machine.json row of a command in the Table is covered by a case" do
    cases = StateTableCases.for(T::Table::COMMANDS)
    T::Table::COMMANDS.each do |command|
      rows = StateTableCases.rows(command)
      assert_operator rows.size, :>, 0, "#{command} has no row"
      rows.each do |row|
        assert(cases.any? { |kase| kase.row == row }, "#{command}: row #{row.inspect} is covered by no case")
      end
    end
  end

  test "every case is a test of its class" do
    CLASSES.each do |test_class, commands|
      defined = test_class.runnable_methods
      StateTableCases.for(commands).each do |kase|
        name = "test_state table: #{kase.name}".gsub(/\s+/, "_")
        assert_includes defined, name, "#{test_class} defines no test for #{kase.name}"
      end
    end
  end

  test "the only cases not served are the rows from Finishing, and every row from Finishing is one (HS-3)" do
    cases = StateTableCases.for(T::Table::COMMANDS)
    not_served = cases.select(&:not_served?)
    finishing_rows = cases.select { |kase| kase.from == "finishing" && !kase.row.nil? }

    assert_operator not_served.size, :>, 0
    assert_equal finishing_rows.map(&:name).sort, not_served.map(&:name).sort
    not_served.each { |kase| assert_equal "invalid_state", kase.expected_refusal, kase.name }
    (cases - not_served).each { |kase| assert_equal kase.refusal, kase.expected_refusal, kase.name }
  end

  test "every state a task can be in has a case for every command that reads one" do
    states = Leverage::Contract.list("task_states")
    StateTableCases.for(T::Table::COMMANDS).group_by(&:command).each do |command, cases|
      next if cases.all? { |kase| kase.from.nil? }

      assert_equal states.sort, cases.map(&:from).uniq.sort, command
    end
  end
end
