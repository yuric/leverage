require "test_helper"
require_relative "entries/owner_controls_support"

# Test 3 (PRD L836) for the owner controls (milestone 3 plan WP6, HE-24 to
# HE-27, HS-3): for promote, edit_contract, hold and resume and every task
# state, the state_machine.json row's move and events, or invalid_state;
# for pause_seat, resume_seat and change_seat (rows from no state), the
# row's events. Finishing has the owner's hold and resume rows. The cases
# come from StateTableCases. Side events
# a row lists only when something else holds (a hold to close, a task the
# seat holds) are proven in the entries' own tests.
class StateTableOwnerControlsTest < ActiveSupport::TestCase
  include OwnerControlsSupport

  COMMANDS = %w[promote edit_contract hold resume pause_seat resume_seat change_seat].freeze

  # The conditional events of each row and the entry test that proves each
  # (test/engine/entries/change_seat_test.rb).
  CONDITIONAL = { "change_seat" => { "task.released" => "disables_seat_holding_working_task" } }.freeze

  def self.group = Leverage::Transitions::Table::OWNER_CONTROLS

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

  test "the log each owner control writes replays to the tables and passes the log audit (tests 1 and 2)" do
    reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "codex"))
    other = scenario.seat(role: "builder", credential: scenario.credential)
    idea = scenario.task(state: "ideas")
    working = scenario.task(state: "working", builder: @builder, criteria: %w[build build review])
    first = Criterion.find_by!(task_id: working.id, position: 1)
    first.update!(state: "passed", passed_at: scenario.database_now)
    scenario.append("criterion.passed", task: working, subject: first, actor_kind: "seat", actor_id: @builder.id)
    in_review = scenario.task(state: "in_review")
    scenario.review(in_review, reviewer: reviewer)
    released = scenario.task(state: "working", builder: other)
    after = scenario.workspace.reload.last_seq

    owner_run("promote", "id" => idea.id)
    owner_run("edit_contract", task_params("edit_contract", idea))
    owner_run("hold", "id" => working.id)
    owner_run("resume", "id" => working.id)
    owner_run("pause_seat", "id" => @builder.id)
    owner_run("resume_seat", "id" => @builder.id)
    owner_run("edit_contract", task_params("edit_contract", working).merge("criteria" => [
      { "text" => "Made-up criterion 1.", "kind" => "build" }, { "text" => "Made-up, changed.", "kind" => "build" },
      { "text" => "Made-up criterion 3.", "kind" => "review" }
    ]))
    owner_run("edit_contract", task_params("edit_contract", in_review))
    owner_run("change_seat", "id" => other.id, "enabled" => false, "name" => "Made-up off")

    assert_equal "passed", first.reload.state
    assert_equal "ready", released.reload.state
    assert_equal [], Leverage::Replay.diff(scenario.workspace_id)
    assert_equal [], Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
  end

  StateTableCases.define(self, COMMANDS) do |kase|
    assert_equal [ "owner" ], kase.who unless kase.invalid_state?
    assert_nil kase.hook

    params, task = prepare(kase)
    outcome, events = owner_run(kase.command, params)

    if kase.refusal
      assert_refused(kase.refusal, outcome)
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
    if state == "finishing"
      return scenario.finishing_task(builder: @builder, actions: [ { kind: "send", state: "approved" } ])
    end

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
