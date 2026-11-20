require "test_helper"
require_relative "state_table_test"
require_relative "state_table_timers_test"
require_relative "state_table_sign_in_test"
require_relative "state_table_accounts_test"

# Test 3 (PRD L836) over the whole of Transitions::Table (milestone 2 plan
# EN-2, WP17). Each of the four groups has its own state-table test, which
# runs one case per state_machine.json row or invalid_state pair; this file
# proves that together they leave nothing out:
#
# - the four groups are the whole Table, each command in exactly one;
# - every command an operation serves (Http::RouteTable, the registry's
#   commands of each operation) has an entry (Table.known?, which also
#   answers for the entries milestone 3 keeps in Table::PENDING until WP10
#   moves them, milestone 3 plan HT-6), and every command of the Table but
#   the timers is served by an operation;
# - every row of every command in the Table is the row of some case, and
#   every case is defined as a test by the group's test class.
class StateTableAllTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  GROUPS = {
    StateTableTest => T::Table::TASK_LOOP,
    StateTableTimersTest => T::Table::TIMERS,
    StateTableSignInTest => T::Table::SIGN_IN,
    StateTableAccountsTest => T::Table::ACCOUNTS
  }.freeze

  test "the four groups are the whole Table, each command in exactly one" do
    commands = GROUPS.values.flatten
    assert_equal commands.uniq, commands, "a command is in two groups"
    assert_equal T::Table::COMMANDS.sort, commands.sort
  end

  test "every command a served operation runs has an entry, and every command but the timers is served" do
    served = Leverage::Http::RouteTable::ROUTES.keys.flat_map do |operation_id|
      Leverage::Contract.registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }
        .fetch("commands")
    end
    served = (served - %w[read report_job_limit report_job_signed_out]).uniq
    served.each { |command| assert T::Table.known?(command), "#{command} is served but has no entry" }
    assert_empty (T::Table::COMMANDS - T::Table::TIMERS) - served, "a command of the Table is not served"
  end

  test "every state_machine.json row of a command in the Table is covered by a case" do
    cases = StateTableCases.for(T::Table::COMMANDS)
    T::Table::COMMANDS.each do |command|
      StateTableCases.rows(command).each do |row|
        assert(cases.any? { |kase| kase.row == row }, "#{command}: row #{row.inspect} is covered by no case")
      end
    end
  end

  test "every case is a test of its group's state-table test class" do
    GROUPS.each do |test_class, commands|
      defined = test_class.runnable_methods
      StateTableCases.for(commands).each do |kase|
        name = "test_state table: #{kase.name}".gsub(/\s+/, "_")
        assert_includes defined, name, "#{test_class} defines no test for #{kase.name}"
      end
    end
  end

  test "every state a task can be in has a case for every command that reads one" do
    states = Leverage::Contract.list("task_states")
    StateTableCases.for(T::Table::COMMANDS).group_by(&:command).each do |command, cases|
      next if cases.all? { |kase| kase.from.nil? }

      assert_equal states.sort, cases.map(&:from).uniq.sort, command
    end
  end
end
