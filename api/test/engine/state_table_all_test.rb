require "test_helper"
require_relative "state_table_test"
require_relative "state_table_timers_test"
require_relative "state_table_sign_in_test"
require_relative "state_table_accounts_test"
require_relative "state_table_handoff_test"
require_relative "state_table_owner_controls_test"
require_relative "state_table_rules_test"
require_relative "state_table_jobs_test"
require_relative "state_table_reviewer_eligibility_test"
require_relative "state_table_finishing_test"
require_relative "state_table_finishing_owner_test"
require_relative "state_table_questions_test"
require_relative "state_table_projects_test"
require_relative "state_table_workspace_test"

# Test 3 (PRD L836) over the whole of Transitions::Table (milestone 2 plan
# EN-2, WP17; milestone 3 plan HT-2, HS-3; milestone 4 plan RT-5, WP13).
# Each state-table test class runs one case per state_machine.json row or
# invalid_state pair for its commands; this file proves that together they
# leave nothing out:
#
# - the thirteen groups are the whole Table of 97, each command in exactly one;
# - the state-table test classes cover the Table, each command in exactly one;
# - the commands the served operations run (Http::RouteTable, the
#   registry's commands of each operation) are exactly the Table's
#   commands except commands whose rows are all the app's;
# - every row of every command in the Table is the row of some case, and
#   every case is defined as a test by its class.
class StateTableAllTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  TABLE_GROUPS = %i[TASK_LOOP TIMERS SIGN_IN ACCOUNTS HANDOFF OWNER_CONTROLS RULES CHECKS JOBS FINISHING
                    QUESTIONS PROJECTS WORKSPACE].freeze

  CLASSES = {
    StateTableTest => T::Table::TASK_LOOP,
    StateTableTimersTest => StateTableTimersTest::COMMANDS + StateTableTimersTest::NEW_COMMANDS + StateTableTimersTest::QUESTION_TIMERS,
    StateTableSignInTest => T::Table::SIGN_IN,
    StateTableAccountsTest => T::Table::ACCOUNTS + StateTableAccountsTest::HANDOFF_ACCOUNTS,
    StateTableHandoffTest => StateTableHandoffTest::COMMANDS,
    StateTableOwnerControlsTest => StateTableOwnerControlsTest::COMMANDS,
    StateTableRulesTest => StateTableRulesTest.commands,
    StateTableJobsTest => StateTableJobsTest::COMMANDS,
    StateTableReviewerEligibilityTest => StateTableReviewerEligibilityTest::COMMANDS,
    StateTableFinishingTest => StateTableFinishingTest::COMMANDS,
    StateTableFinishingOwnerTest => %w[waive_action mark_action_done offer_task_again return_for_rework overturn_approval],
    StateTableQuestionsTest => %w[ask_question request_access answer_question overturn_answer grant_access],
    StateTableProjectsTest => StateTableProjectsTest::COMMANDS,
    StateTableWorkspaceTest => %w[delete_content change_workspace_settings]
  }.freeze

  # The commands whose every state_machine.json row is the app's: no
  # operation runs them.
  def app_only = T::Table::COMMANDS.select { |command| StateTableCases.rows(command).all? { |row| row.fetch("who") == %w[app] } }

  test "the thirteen groups are the whole Table of 97, each command in exactly one" do
    assert_equal 97, T::Table::COMMANDS.size
    commands = TABLE_GROUPS.flat_map { |group| T::Table.const_get(group) }
    assert_equal commands.uniq, commands, "a command is in two groups"
    assert_equal T::Table::COMMANDS.sort, commands.sort
    assert_equal 97, commands.size
  end

  test "the state-table test classes cover the Table, each command in exactly one" do
    commands = CLASSES.values.flatten
    assert_equal commands.uniq, commands, "a command is walked by two classes"
    assert_equal T::Table::COMMANDS.sort, commands.sort
  end

  test "the app alone runs the timers, installs shipped rules and requests actions or grants their leases" do
    assert_equal (T::Table::TIMERS + %w[install_shipped_rules request_action grant_action_lease]).sort, app_only.sort
  end

  test "the commands the served operations run are exactly the Table's commands but those the app alone runs" do
    served = Leverage::Http::RouteTable::ROUTES.keys.flat_map do |operation_id|
      Leverage::Contract.registry.fetch("operations").find { |op| op.fetch("operation_id") == operation_id }
        .fetch("commands")
    end
    served = (served - %w[read]).uniq
    assert_equal (T::Table::COMMANDS - app_only).sort, served.sort
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

  test "every state a task can be in has a case for every command that reads one" do
    states = Leverage::Contract.list("task_states")
    StateTableCases.for(T::Table::COMMANDS).group_by(&:command).each do |command, cases|
      next if cases.all? { |kase| kase.from.nil? }

      assert_equal states.sort, cases.map(&:from).uniq.sort, command
    end
  end
end
