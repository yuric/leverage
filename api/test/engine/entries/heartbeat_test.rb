require "test_helper"

# Heartbeat (PRD L119, L263, L495, L546): the holder renews its lease; no
# event. After the lease ended it is lease_expired, and after a cancel
# task_cancelled (trace 10). Allowed under a hold.
class HeartbeatTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @builder = @scenario.seat(role: "builder")
    @task = @scenario.task(state: "working", builder: @builder)
  end

  def apply(seat, task = @task)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "heartbeat", workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: "heartbeat", params: { "id" => task.id }))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  test "renews the lease from now and writes no event" do
    @task.update_columns(lease_due_at: @scenario.database_now + 5)
    before = @scenario.database_now
    outcome = apply(@builder)

    assert outcome.completed?
    due = @task.reload.lease_due_at
    assert_operator due, :>=, before + 600
    assert_equal({ "lease_due_at" => due.utc.iso8601(6) }, outcome.result)
    assert_empty written
    assert Command.exists?(key: @key, outcome: "completed")
  end

  test "it is allowed while the task is held" do
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "rounds_exceeded", facts: { round: 0 })
    end
    assert apply(@builder).completed?
  end

  test "it clears a pending resume" do
    @task.update_columns(resume_pending_since: @scenario.database_now)
    apply(@builder)
    assert_nil @task.reload.resume_pending_since
  end

  test "after the lease expired it is lease_expired" do
    @task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.lease_expired", task: @task, payload: { wait_cause: nil })
    assert_equal "lease_expired", apply(@builder).refusal.code
  end

  test "after a cancel the former holder is told task_cancelled" do
    @task.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.cancelled", task: @task, actor_kind: "owner", actor_id: @scenario.owner.id)
    assert_equal "task_cancelled", apply(@builder).refusal.code
  end

  test "a seat that does not hold the task is not_holder" do
    assert_equal "not_holder", apply(@scenario.seat(role: "builder")).refusal.code
  end
end
