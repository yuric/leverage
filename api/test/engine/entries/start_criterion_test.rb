require "test_helper"

# Start criterion (PRD Lifecycle L86, L473, L496): optional; the builder
# announces the criterion it works on. A work call: the briefing must be
# acknowledged. Not blocked by a hold (state_machine.json).
class StartCriterionTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  B = Leverage::Briefing

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @task = @scenario.task(state: "working", builder: @builder)
    @criterion = Criterion.where(task_id: @task.id, kind: "build").order(:position).first
  end

  def apply(command, seat, params)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def acknowledge = apply("acknowledge_briefing", @builder, "id" => @task.id, "briefing_hash" => B.hash_for(@task, seat: @builder))

  def start(criterion = @criterion) = apply("start_criterion", @builder, "id" => @task.id, "cid" => criterion.id)

  test "writes criterion.started about the criterion, which is started" do
    acknowledge
    assert start.completed?

    event = written.sole
    assert_equal [ "criterion.started", "seat", @builder.id, "criterion", @criterion.id, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.payload ]
    assert_equal "started", @criterion.reload.state
  end

  test "before the briefing is acknowledged it is briefing_not_acknowledged" do
    assert_equal "briefing_not_acknowledged", start.refusal.code
    assert_empty written
  end

  test "after the briefing changed it is briefing_changed" do
    acknowledge
    @task.update_columns(contract_version: @task.contract_version + 1)
    assert_equal "briefing_changed", start.refusal.code
  end

  test "a passed criterion started again is started, and must be passed again" do
    acknowledge
    @criterion.update!(state: "passed", passed_at: @scenario.database_now, passed_by_seat_id: @builder.id)
    assert start.completed?
    assert_equal [ "started", nil, nil ], @criterion.reload.attributes.values_at("state", "passed_at", "passed_by_seat_id")
  end

  test "it is allowed while the task is held" do
    acknowledge
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "rounds_exceeded", facts: { round: 0 })
    end
    assert start.completed?
  end

  test "the review criterion is 422 invalid; another task's criterion is not found" do
    acknowledge
    review_criterion = Criterion.find_by!(task_id: @task.id, kind: "review")
    assert_raises(T::Invalid) { start(review_criterion) }
    other = Criterion.where(task_id: @scenario.task(state: "ready").id).first
    assert_raises(T::NotFound) { start(other) }
  end

  test "a seat that does not hold the task is not_holder; a reviewer that does not, not_holder before forbidden" do
    other = @scenario.seat(role: "builder")
    assert_equal "not_holder", apply("start_criterion", other, "id" => @task.id, "cid" => @criterion.id).refusal.code
    reviewer = @scenario.seat(role: "reviewer")
    assert_equal "not_holder", apply("start_criterion", reviewer, "id" => @task.id, "cid" => @criterion.id).refusal.code
  end
end
