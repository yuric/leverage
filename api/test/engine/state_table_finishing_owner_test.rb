require "test_helper"
require_relative "entries/accounts_support"
require_relative "../support/state_table_cases"

# WP5 owns the rows; WP4 owns the action writes and Finishing settlement.
# The substitutes record the boundary calls and write just enough of their
# events to test each entry's ordering under the real command pipeline.
class StateTableFinishingOwnerTest < ActiveSupport::TestCase
  include AccountsSupport

  ACTIONS = Leverage::Actions
  FINISHING = Leverage::Finishing

  setup { use_scenario }

  StateTableCases.define(self, %w[waive_action mark_action_done offer_task_again return_for_rework overturn_approval]) do |row|
    @row = row
    @guard = row.guard
    @calls = []
    prepare_case
    written = with_methods(substitutes) do
      events_written do
        outcome = owner_command(row.command, params)
        row.refusal ? assert_refused(row.refusal, outcome) : assert_completed(outcome)
      end
    end

    if row.refusal
      assert_empty @calls
      assert_empty written
    else
      assert_equal row.to, @task.reload.state
      assert_equal row.events, written.map(&:type).select { |type| row.events.include?(type) }
      assert_calls_and_lease(written)
    end
  end

  private

  def prepare_case
    finishing = @row.from == "finishing"
    held = @guard.include?("builder_holds_task")
    state = action_state
    @task = if finishing
      specifications = [ { state: state, description: "Made-up action." } ]
      specifications << { state: "approved", description: "Another made-up action." } if held || @guard.include?("not_last_open_action")
      scenario.finishing_task(holder: held, actions: specifications)
    else
      scenario.task(state: @row.from)
    end
    @action = Action.where(task_id: @task.id).order(:position).first
    @action ||= Action.create!(workspace_id: @task.workspace_id, task_id: @task.id, position: 1,
      kind: "publish", description: "Made-up action.", state: state)
    if @row.command == "overturn_approval"
      @action.update!(approved_by_kind: "seat", approved_by_id: scenario.orchestrator.id)
      if @guard.include?("approval_already_overturned")
        scenario.append("action.overturn_recorded", task: @task, subject: @action, actor_kind: "owner", actor_id: scenario.owner.id)
      end
    end
    if @guard.include?("held_owner_approval")
      scenario.hold(@task, reason: "owner_approval", facts: { action_id: @action.id })
    end
    if @guard.include?("held_action_unconfirmed")
      scenario.hold(@task, reason: "action_unconfirmed", facts: { action_ids: [ @action.id ],
        approved_by_kind: "owner", approved_by_id: scenario.owner.id, builder_announced_start: false })
    end
    Seat.find(@task.builder_seat_id).update!(enabled: false) if @guard.include?("builder_seat_unavailable")
    @task.reload
  end

  def action_state
    return "requested" if @guard.include?("held_owner_approval")
    return "done" if @guard.include?("approved_action_done")
    return "started" if @guard.include?("action_started")
    return "approved" if %w[mark_action_done offer_task_again overturn_approval].include?(@row.command)

    "stopped"
  end

  def params
    case @row.command
    when "return_for_rework" then { "id" => @task.id, "criterion_ids" => [] }
    when "offer_task_again" then { "id" => @task.id }
    else { "id" => @action.id }
    end
  end

  def substitutes
    steps = Leverage::Steps.method(:on_event)
    {
      [ ACTIONS, :last_open? ] => ->(action) { @guard.include?("last_open_action") && action == @action },
      [ ACTIONS, :approvals_complete? ] => ->(task) { @guard.include?("approvals_complete") && task == @task },
      [ ACTIONS, :any_started? ] => ->(task) { @guard.include?("action_started") && task == @task },
      [ FINISHING, :builder_free? ] => ->(task, lease:, at: Time.current) {
        assert_equal(@row.command == "return_for_rework" ? :task : :action, lease)
        @guard.include?("builder_free") && task == @task
      },
      [ FINISHING, :builder_holds_task? ] => ->(task) { @guard.include?("builder_holds_task") && task == @task },
      [ ACTIONS, :waive ] => ->(ctx, action) { waive(ctx, action) },
      [ ACTIONS, :mark_done ] => ->(ctx, action) { write_action(ctx, action, "action.marked_done", "done") },
      [ ACTIONS, :withdraw_open ] => ->(ctx, task) { withdraw_open(ctx, task) },
      [ ACTIONS, :stop ] => ->(ctx, action, by:) { stop(ctx, action, by: by) },
      [ ACTIONS, :record_overturn ] => ->(ctx, action) { write_action(ctx, action, "action.overturn_recorded", "done") },
      [ FINISHING, :settle ] => ->(ctx, task, by:) { settle(ctx, task, by: by) },
      [ FINISHING, :after_command ] => ->(_ctx) { },
      [ Leverage::Steps, :on_event ] => ->(ctx, event) { steps.call(ctx, event) unless step_events_owned_by_wp4.include?(event.type) }
    }
  end

  def step_events_owned_by_wp4
    %w[action.waived action.marked_done action.withdrawn action.stopped task.returned_for_rework]
  end

  def waive(ctx, action)
    lease_seat_id = @task.builder_seat_id if @row.builder_lease == "fresh"
    write_action(ctx, action, "action.waived", "waived", lease_seat_id: lease_seat_id)
  end

  def write_action(ctx, action, type, state, **payload)
    @calls << [ type, ctx.request.command, action.id ]
    action.update!(state: state)
    ctx.emit(type, task: @task, subject: action, payload: payload)
  end

  def withdraw_open(ctx, task)
    @calls << [ "withdraw_open", ctx.request.command, task.id ]
    @action.update!(state: "contracted")
    ctx.emit("action.withdrawn", task: task, subject: @action)
  end

  def stop(ctx, action, by:)
    assert_equal ctx.actor, by
    stopped = write_action(ctx, action, "action.stopped", "stopped", overturned: ctx.request.command == "overturn_approval")
    Leverage::Holds.open(ctx, task: @task, reason: "action_stopped", cause_id: stopped.id,
      actor_kind: by.first, actor_id: by.last,
      facts: { action_id: action.id, rule_check_id: nil, any_action_started: false })
  end

  def settle(ctx, task, by:)
    @calls << [ "settle", ctx.request.command, task.id, by.type ]
    return unless @guard.include?("last_open_action")

    Leverage::Leases.end_lease(ctx, task)
    task.update!(state: "done", holder_seat_id: nil)
    ctx.emit("task.done", task: task)
  end

  def assert_calls_and_lease(written)
    command = @row.command
    case command
    when "waive_action"
      assert_equal [ [ "action.waived", command, @action.id ], [ "settle", command, @task.id, "action.waived" ] ], @calls
    when "mark_action_done"
      assert_equal [ [ "action.marked_done", command, @action.id ], [ "settle", command, @task.id, "hold.closed" ] ], @calls
    when "offer_task_again"
      assert_equal [ [ "settle", command, @task.id, "hold.closed" ] ], @calls
    when "return_for_rework"
      assert_equal [ [ "withdraw_open", command, @task.id ] ], @calls
    when "overturn_approval"
      assert_equal [ [ @row.events.first, command, @action.id ] ], @calls
    end
    types = written.map(&:type)
    if @guard.include?("last_open_action")
      if command == "mark_action_done"
        assert_equal %w[action.marked_done hold.closed task.done inbox.resolved], types
      elsif command == "waive_action"
        assert_equal %w[action.waived task.done hold.closed inbox.resolved], types
      end
    end
    grantees = written.filter_map { |event| event.payload["lease_seat_id"] }
    assert_equal(@row.builder_lease == "fresh" ? [ @task.builder_seat_id ] : [], grantees)
  end

  def with_methods(overrides)
    originals = overrides.keys.to_h { |mod, name| [ [ mod, name ], mod.method(name) ] }
    overrides.each do |(mod, name), substitute|
      mod.define_singleton_method(name) { |*args, **kwargs| substitute.call(*args, **kwargs) }
    end
    yield
  ensure
    originals.each { |(mod, name), original| mod.define_singleton_method(name, original) }
  end
end
