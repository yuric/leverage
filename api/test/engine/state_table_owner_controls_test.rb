require "test_helper"
require_relative "entries/owner_controls_support"

# Test 3 (PRD L836) for the owner controls (milestone 3 plan WP6, HE-24 to
# HE-27, HS-3): for promote, edit_contract, hold and resume and every task
# state, the state_machine.json row's move and events, or invalid_state;
# for pause_seat, resume_seat and change_seat (rows from no state), the
# row's events. A row from Finishing is not served in this milestone and is
# proven refused invalid_state from a task Scenario puts there. The cases
# come from StateTableCases, so nothing here retypes the table. Side events
# a row lists only when something else holds (a hold to close, a task the
# seat holds) are proven in the entries' own tests.
class StateTableOwnerControlsTest < ActiveSupport::TestCase
  include OwnerControlsSupport

  COMMANDS = %w[promote edit_contract hold resume pause_seat resume_seat change_seat].freeze

  # The conditional events of each row and the entry test that proves each
  # (test/engine/entries/change_seat_test.rb).
  CONDITIONAL = { "change_seat" => { "task.released" => "disables_seat_holding_working_task" } }.freeze

  def self.group
    table = Leverage::Transitions::Table
    table.const_defined?(:OWNER_CONTROLS) ? table::OWNER_CONTROLS : table::PENDING_GROUPS.fetch("OWNER_CONTROLS")
  end

  setup do
    use_scenario
    @builder = scenario.seat(role: "builder", credential: scenario.credential)
  end

  test "the owner controls are the seven commands of plan section 2.1" do
    assert_equal COMMANDS, self.class.group
  end

  test "every conditional event of the group is named here and proven by its entry's test" do
    StateTableCases.for(COMMANDS).each do |kase|
      named = kase.conditional_events.to_h { |conditional| [ conditional.fetch("event"), conditional.fetch("when") ] }
      assert_equal CONDITIONAL.fetch(kase.command, {}), named, kase.command
    end
  end

  test "the rows from Finishing are hold and resume, each marked not served (HS-3)" do
    finishing = StateTableCases.for(COMMANDS).select(&:not_served?)

    assert_equal [ [ "hold", [] ], [ "resume", [ "not_held_owner_hold" ] ], [ "resume", [ "held_owner_hold" ] ] ],
      finishing.map { |kase| [ kase.command, kase.guard ] }
  end

  StateTableCases.define(self, COMMANDS) do |kase|
    assert_equal [ "owner" ], kase.who unless kase.invalid_state?
    assert_nil kase.hook

    params, task = prepare(kase)
    outcome, events = owner_run(kase.command, params)

    if kase.expected_refusal
      assert_refused(kase.expected_refusal, outcome)
      assert_empty events, kase.name
    else
      assert_completed(outcome)
      assert_equal kase.events, events.map(&:type), kase.name
      assert_equal kase.to, task.reload.state if kase.to
    end
  end

  private

  # The params of the case's command, and the task it is about (nil for a
  # seat command).
  def prepare(kase)
    case kase.command
    when "pause_seat" then [ { "id" => @builder.id }, nil ]
    when "resume_seat" then [ { "id" => scenario.pause_seat(@builder).id }, nil ]
    when "change_seat" then [ { "id" => @builder.id, "name" => "Made-up renamed seat" }, nil ]
    else
      task = task_in(kase.from)
      owner_hold(task) if kase.guard.include?("held_owner_hold")
      [ task_params(kase.command, task), task ]
    end
  end

  def task_in(state)
    return scenario.finishing_task(builder: @builder) if state == "finishing"

    scenario.task(state: state, builder: (@builder if state == "working"))
  end

  # An owner_hold the owner opened, through Holds (not through the hold
  # command, so that resume's rows do not depend on hold's).
  def owner_hold(task)
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(scenario.context, task: task, reason: "owner_hold", actor_kind: "owner",
        actor_id: scenario.owner.id)
    end
  end

  def task_params(command, task)
    return { "id" => task.id } unless command == "edit_contract"

    { "id" => task.id, "title" => task.title, "goal" => task.goal, "details" => nil,
      "criteria" => [ { "text" => "Made-up build criterion.", "kind" => "build" },
                      { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }
  end
end
