require "test_helper"
require_relative "entries/jobs_support"

# The state table rows for cost reports, task changes, and project commands
# (milestone 5 WP7). Conditional events are exercised by the budget and
# project tests.
class StateTableProjectsTest < ActiveSupport::TestCase
  include JobsSupport

  COMMANDS = %w[report_cost change_task_priority change_task_project change_task_cap
                change_budget pause_project resume_project create_project edit_brief
                install_imaginarium_project].freeze

  setup { use_scenario }

  StateTableCases.define(self, COMMANDS) do |kase|
    task, caller, params = prepare(kase)

    outcome = nil
    events = events_written do
      assert_nothing_raised do
        outcome = if caller == :app
          Leverage::Timers.apply_workspace(scenario.workspace, kase.command, at: scenario.database_now)
        else
          caller ? seat_command(caller, kase.command, params) : owner_command(kase.command, params)
        end
      end
    end

    if kase.refusal
      assert_refused(kase.refusal, outcome)
      assert_empty events
      assert_equal kase.from, task.reload.state
    else
      assert_completed(outcome)
      assert_equal kase.events, types(events)
      assert_equal kase.to, task.reload.state if kase.to
    end
  end

  private

  def prepare(kase)
    case kase.command
    when "report_cost"
      cost_report(kase)
    when "change_task_priority"
      [ nil, nil, { "id" => scenario.task.id, "priority" => "high" } ]
    when "change_task_project"
      [ nil, nil, { "id" => scenario.task.id, "project_id" => scenario.project.id } ]
    when "change_task_cap"
      [ nil, nil, { "id" => scenario.task.id, "budget_cap" => 12 } ]
    when "change_budget"
      [ nil, nil, { "id" => scenario.project(budget: 5).id, "budget" => 12 } ]
    when "pause_project"
      [ nil, nil, { "id" => scenario.project.id } ]
    when "resume_project"
      project = scenario.project(paused: true)
      scenario.append("project.paused", project_id: project.id, actor_kind: "owner", actor_id: scenario.owner.id)
      [ nil, nil, { "id" => project.id } ]
    when "install_imaginarium_project"
      [ nil, :app, {} ]
    when "create_project"
      [ nil, nil, { "name" => "Made-up new project" } ]
    when "edit_brief"
      [ nil, nil, { "id" => scenario.project.id,
                    "entries" => [ { "kind" => "lesson", "text" => "Use the sample data." } ] } ]
    end
  end

  def cost_report(kase)
    builder = scenario.seat(role: "builder")
    task = if kase.from == "finishing"
      scenario.finishing_task(builder: builder, actions: [
        { kind: "send", description: "Send a made-up note.", state: "approved" }
      ])
    else
      scenario.task(state: kase.from, builder: builder)
    end
    # Isolate the unlisted state guard from the higher-precedence holder
    # guard. Scenario still builds the task's state and its history.
    task.update!(holder_seat_id: builder.id, lease_due_at: from_now(120)) if kase.invalid_state?

    [ task, builder, { "id" => task.id, "tokens" => 80, "spend" => 0.125 } ]
  end
end
