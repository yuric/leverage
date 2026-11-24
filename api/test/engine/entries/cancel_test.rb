require "test_helper"

# Cancel (PRD Lifecycle L106, L207; milestone 2 plan EN-30): from Backlog,
# Ready, Working or In review the task is Cancelled. It ends the builder's
# lease and any review lease, closes every open hold, resolves the task's
# Needs you items, and writes task.cancelled first. Both seats are free at
# once, and the holder's next call is refused task_cancelled. Done is
# invalid_state.
class CancelTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @builder = @scenario.seat(role: "builder")
    @reviewer = @scenario.seat(role: "reviewer")
  end

  def apply(command, caller, params)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id,
      caller_kind: caller.is_a?(Seat) ? "seat" : "owner", caller_id: caller.id, key: key,
      request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def cancel(task) = apply("cancel", @owner, "id" => task.id)

  test "cancels a Working task: no holder, no builder, no lease, task.cancelled" do
    task = @scenario.task(state: "working", builder: @builder)
    assert cancel(task).completed?

    task.reload
    assert_equal [ "cancelled", nil, nil, nil ], task.attributes.values_at("state", "holder_seat_id", "builder_seat_id", "lease_due_at")
    event = written.sole
    assert_equal [ "task.cancelled", "owner", @owner.id, {} ], [ event.type, event.actor_kind, event.actor_id, event.payload ]
  end

  test "the builder is free at once, and its next call on the task is task_cancelled" do
    task = @scenario.task(state: "working", builder: @builder)
    cancel(task)

    assert_equal "task_cancelled", apply("heartbeat", @builder, "id" => task.id).refusal.code
    @scenario.task(state: "ready")
    assert apply("claim", @builder, {}).completed?
  end

  test "cancelling a task In review ends the review lease and frees the reviewer" do
    task = @scenario.task(state: "in_review", builder: @builder)
    review = @scenario.review(task, reviewer: @reviewer)
    assert cancel(task).completed?

    assert_equal [ nil, nil ], review.reload.attributes.values_at("reviewer_seat_id", "lease_due_at")
    assert_equal "task_cancelled", apply("heartbeat_review", @reviewer, "id" => review.id).refusal.code
    assert Leverage::Eligibility.may_claim?(@reviewer.reload, :review)
  end

  test "cancel closes every open hold and resolves its item with the choice cancel" do
    task = @scenario.task(state: "working", builder: @builder)
    hold = ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: task, reason: "rounds_exceeded", facts: { round: 0 })
    end
    assert cancel(task).completed?

    assert_equal %w[task.cancelled hold.closed inbox.resolved], written.map(&:type)
    closed, resolved = written.last(2)
    assert_equal [ "owner", @owner.id ], [ closed.actor_kind, closed.actor_id ]
    assert_equal({ "reason" => "rounds_exceeded", "rule_id" => nil, "credential_id" => nil, "lease_seat_id" => nil,
                   "wait_cause" => nil }, closed.payload)
    assert_equal({ "choice" => "cancel" }, resolved.payload)
    assert hold.reload.closed_at
    assert_equal "resolved", InboxItem.find_by!(hold_id: hold.id).state
  end

  test "Ideas, Backlog, Ready and In review cancel too" do
    %w[ideas backlog ready in_review].each do |state|
      task = @scenario.task(state: state)
      assert cancel(task).completed?, state
      assert_equal "cancelled", task.reload.state
    end
  end

  test "Done and Cancelled are invalid_state" do
    done = @scenario.task(state: "done")
    assert_equal "invalid_state", cancel(done).refusal.code
    assert_empty written
    assert_equal "invalid_state", cancel(@scenario.task(state: "cancelled")).refusal.code
  end

  test "an unknown task is not found" do
    assert_raises(T::NotFound) { apply("cancel", @owner, "id" => SecureRandom.uuid) }
  end
end
