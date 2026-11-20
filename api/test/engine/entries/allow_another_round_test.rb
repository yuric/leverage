require "test_helper"

# Allow one more round (PRD L163, L191; milestone 2 plan EN-31, DB-15): with
# an open rounds_exceeded hold, the owner adds one to the task's extra
# rounds and closes the hold, resolving the Past the round limit item with
# the choice allow_another_round. Without that hold it is invalid_state.
class AllowAnotherRoundTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @builder = @scenario.seat(role: "builder")
    @task = @scenario.task(state: "working", builder: @builder)
  end

  def apply(task = @task)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "allow_another_round", workspace_id: @scenario.workspace_id, caller_kind: "owner",
      caller_id: @owner.id, key: key, request_hash: "another", params: { "id" => task.id }))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def hold(reason, task = @task)
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: task, reason: reason, facts: reason == "rounds_exceeded" ? { round: 3 } : {})
    end
  end

  test "adds one round and closes the rounds_exceeded hold with its item" do
    held = hold("rounds_exceeded")
    assert apply.completed?

    assert_equal 1, @task.reload.extra_rounds
    assert held.reload.closed_at
    assert_equal %w[hold.closed inbox.resolved], written.map(&:type)
    closed, resolved = written
    assert_equal [ "owner", @owner.id, "hold", held.id ], [ closed.actor_kind, closed.actor_id, closed.subject_kind, closed.subject_id ]
    assert_nil closed.payload["lease_seat_id"]
    assert_equal({ "choice" => "allow_another_round" }, resolved.payload)
    assert_equal "resolved", InboxItem.find_by!(hold_id: held.id).state
  end

  test "without an open rounds_exceeded hold it is invalid_state" do
    assert_equal "invalid_state", apply.refusal.code
    hold("owner_hold")
    assert_equal "invalid_state", apply.refusal.code
    assert_empty written
    assert_equal 0, @task.reload.extra_rounds
  end

  test "it leaves other open holds open" do
    hold("rounds_exceeded")
    other = hold("owner_hold")
    assert apply.completed?
    assert_nil other.reload.closed_at
  end

  test "an unknown task is not found" do
    assert_raises(T::NotFound) do
      T.apply(T::Request.new(command: "allow_another_round", workspace_id: @scenario.workspace_id, caller_kind: "owner",
        caller_id: @owner.id, key: "key-unknown", request_hash: "x", params: { "id" => SecureRandom.uuid }))
    end
  end
end
