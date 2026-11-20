require "test_helper"

# Acknowledge briefing (PRD Lifecycle L84, The briefing L473; DB-11): the
# holder acknowledges the current hash under its lease. The acknowledgement
# is kept per seat, per lease and per hash, and task.briefing_acknowledged
# is written with no subject.
class AcknowledgeBriefingTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  B = Leverage::Briefing

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @task = @scenario.task(state: "working", builder: @builder)
  end

  def apply(seat, params)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: "acknowledge_briefing", workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def current(task = @task, seat = @builder) = { "id" => task.id, "briefing_hash" => B.hash_for(task, seat: seat) }

  test "acknowledges the current hash under the lease the claim granted" do
    outcome = apply(@builder, current)

    assert outcome.completed?
    event = written.sole
    assert_equal [ "task.briefing_acknowledged", "seat", @builder.id, nil, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.payload ]
    row = BriefingAcknowledgement.find_by!(task_id: @task.id)
    claimed = Event.find_by!(task_id: @task.id, type: "task.claimed")
    assert_equal [ @builder.id, nil, claimed.id, B.hash_for(@task, seat: @builder) ],
      row.attributes.values_at("seat_id", "review_id", "lease_event_id", "briefing_hash")
    assert_equal :current, B.acknowledgement(@task, seat: @builder)
  end

  test "a hash that is not the current one is briefing_changed and writes nothing" do
    outcome = apply(@builder, "id" => @task.id, "briefing_hash" => "briefing-hash-made-up")
    assert_equal "briefing_changed", outcome.refusal.code
    assert_empty written
    assert_equal 0, BriefingAcknowledgement.where(task_id: @task.id).count
  end

  test "the same hash twice under one lease keeps one row and writes the event again" do
    apply(@builder, current)
    assert apply(@builder, current).completed?
    assert_equal [ "task.briefing_acknowledged" ], written.map(&:type)
    assert_equal 1, BriefingAcknowledgement.where(task_id: @task.id).count
  end

  test "a fresh lease after a failed review is acknowledged under its review.failed" do
    apply(@builder, current)
    review = Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 0, verdict: "failed")
    failed = @scenario.append("review.failed", task: @task, subject: review, actor_kind: "seat",
      actor_id: @scenario.seat(role: "reviewer").id,
      payload: { failed_criterion_ids: [], failed_rule_check_id: nil, lease_seat_id: @builder.id, wait_cause: nil })
    assert_equal :missing, B.acknowledgement(@task, seat: @builder)

    assert apply(@builder, current).completed?
    assert BriefingAcknowledgement.exists?(task_id: @task.id, seat_id: @builder.id, lease_event_id: failed.id)
    assert_equal 2, BriefingAcknowledgement.where(task_id: @task.id).count
    assert_equal :current, B.acknowledgement(@task, seat: @builder)
  end

  test "it is allowed while the task is held, and clears a pending resume" do
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "rounds_exceeded", facts: { round: 0 })
    end
    @task.update_columns(resume_pending_since: @scenario.database_now)

    assert apply(@builder, current).completed?
    assert_nil @task.reload.resume_pending_since
  end

  test "a seat that does not hold the task is not_holder" do
    other = @scenario.seat(role: "builder")
    assert_equal "not_holder", apply(other, current(@task, other)).refusal.code
  end

  test "after the lease expired it is lease_expired; after a cancel, task_cancelled" do
    @task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.lease_expired", task: @task, payload: { wait_cause: nil })
    assert_equal "lease_expired", apply(@builder, current).refusal.code

    held = @scenario.task(state: "working", builder: (seat = @scenario.seat(role: "builder")))
    held.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.cancelled", task: held, actor_kind: "owner", actor_id: @scenario.owner.id)
    assert_equal "task_cancelled", apply(seat, current(held, seat)).refusal.code
  end

  test "an unknown task is not found" do
    assert_raises(T::NotFound) { apply(@builder, "id" => SecureRandom.uuid, "briefing_hash" => "made-up") }
  end
end
