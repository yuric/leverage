require "test_helper"
require_relative "handoff_support"

class ReturnForReworkTest < ActiveSupport::TestCase
  include HandoffSupport

  setup do
    use_scenario(lease_length_seconds: 600, maximum_rounds: 1)
    @builder = own_seat
    @task = scenario.finishing_task(builder: @builder, holder: true, criteria: %w[build build review],
      actions: %w[approved stopped requested].map { |state| { state: state, description: "Made-up action." } })
    @untouched, @named, @review = Criterion.where(task_id: @task.id).order(:position).to_a
  end

  test "reopens the named and review criteria and withdraws actions before closing their holds" do
    approved, _stopped, requested = Action.where(task_id: @task.id).order(:position).to_a
    stopped_hold = Hold.find_by!(task_id: @task.id, reason: "action_stopped")
    approval = scenario.hold(@task, reason: "owner_approval", facts: { action_id: requested.id })
    unconfirmed = scenario.hold(@task, reason: "action_unconfirmed", facts: {
      action_ids: [ approved.id ], approved_by_kind: "owner", approved_by_id: scenario.owner.id,
      builder_announced_start: false
    })
    error = check_error_hold(requested)
    unrelated = scenario.hold(@task, reason: "owner_hold")
    action_holds = [ stopped_hold, approval, unconfirmed, error ]
    withdrawals = []
    withdraw = lambda do |ctx, task|
      withdrawals << [ ctx.request.command, task.id, ctx.events.map(&:type),
        action_holds.map { |hold| hold.reload.closed_at } ]
    end

    events = events_written do
      with_rework_seams(withdraw: withdraw) { assert_completed(rework([ @review.id, @named.id ])) }
    end

    assert_equal [ [ "return_for_rework", @task.id,
                    %w[task.returned_for_rework criterion.reopened criterion.reopened], [ nil, nil, nil, nil ] ] ], withdrawals
    assert_equal [ @named.id, @review.id ], events.select { |event| event.type == "criterion.reopened" }.map(&:subject_id)
    assert_equal "passed", @untouched.reload.state
    [ @named, @review ].each do |criterion|
      assert_equal [ "open", nil, nil ], criterion.reload.attributes.values_at("state", "passed_at", "passed_by_seat_id")
    end
    assert_equal action_holds.map(&:id).sort, events.select { |event| event.type == "hold.closed" }.map(&:subject_id).sort
    resolved = events.select { |event| event.type == "inbox.resolved" }.index_by(&:subject_id)
    action_holds.zip([ "return_for_rework", nil, nil, nil ]).each do |hold, choice|
      assert hold.reload.closed_at
      item = InboxItem.find_by!(hold_id: hold.id)
      assert_equal "resolved", item.state
      assert_equal choice, resolved.fetch(item.id).payload.fetch("choice") if choice
      assert_nil resolved.fetch(item.id).payload.fetch("choice") if choice.nil?
    end
    assert_nil unrelated.reload.closed_at
    assert_equal [ "working", 1, @builder.id, @builder.id ],
      @task.reload.attributes.values_at("state", "round", "builder_seat_id", "holder_seat_id")
    assert_equal [ 0 ], events.map(&:round).uniq
    assert_not_includes events.map(&:type), "task.reassigned"
    assert_not_includes events.map(&:type), "hold.opened"
  end

  test "replaces the paused action lease with a full lease when the clock steps back" do
    assert @task.reload.lease_time_left_while_paused
    @task.update!(lease_time_left_while_paused: 10.seconds)
    previous = Event.where(workspace_id: scenario.workspace_id).order(:seq).last
    events = events_written do
      with_methods(Leverage::WorkspaceLock, clock: -> { previous.at - 1 }) do
        with_rework_seams { assert_completed(rework([])) }
      end
    end

    returned = events.find { |event| event.type == "task.returned_for_rework" }
    assert_operator returned.at, :>, previous.at
    assert_equal @builder.id, returned.payload.fetch("lease_seat_id")
    assert_equal returned.at + 600, @task.reload.lease_due_at
    assert_nil @task.lease_time_left_while_paused
    assert_equal [ @review.id ], events.select { |event| event.type == "criterion.reopened" }.map(&:subject_id)
  end

  test "rejects a malformed criterion id and a criterion from another task" do
    foreign = Criterion.find_by!(task_id: scenario.task(state: "ready").id, kind: "build")
    events = events_written do
      [ [ "invalid-uuid" ], [ foreign.id ] ].each do |ids|
        assert_raises(Leverage::Transitions::Invalid) { rework(ids) }
      end
    end
    assert_empty events
    assert_equal [ "finishing", 0 ], @task.reload.attributes.values_at("state", "round")
  end

  private

  def rework(ids)
    owner_command("return_for_rework", { "id" => @task.id, "criterion_ids" => ids })
  end

  def check_error_hold(action)
    rule = scenario.rule(hook: "action.requested")
    check = scenario.rule_check(@task, rule: rule, result: "error", subject: action)
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(scenario.context, task: @task, reason: "check_error", rule_id: rule.id,
        rule_check_id: check.id, facts: { rule_id: rule.id, rule_check_id: check.id })
    end
  end

  def with_rework_seams(withdraw: ->(_ctx, _task) {}, &block)
    steps = Leverage::Steps.method(:on_event)
    track = ->(ctx, event) { steps.call(ctx, event) unless event.type == "task.returned_for_rework" }
    with_methods(Leverage::Steps, on_event: track) do
      with_methods(Leverage::Finishing, builder_free?: ->(*) { false }, builder_holds_task?: ->(*) { true }) do
        with_methods(Leverage::Actions, any_started?: ->(*) { false }, withdraw_open: withdraw, &block)
      end
    end
  end

  def with_methods(mod, **methods)
    originals = methods.keys.to_h { |name| [ name, mod.method(name) ] }
    methods.each { |name, body| mod.define_singleton_method(name, &body) }
    yield
  ensure
    originals&.each { |name, original| mod.define_singleton_method(name, original) }
  end
end
