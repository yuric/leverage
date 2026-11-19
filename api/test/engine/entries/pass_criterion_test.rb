require "test_helper"

# Pass criterion (PRD Lifecycle L87, L497, L533; milestone 2 plan EN-15):
# the builder passes a criterion with evidence, an https link or a note;
# criterion.passed and evidence.attached are written. A work call, blocked
# by a hold.
class PassCriterionTest < ActiveSupport::TestCase
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

  def pass(kind: "link", value: "https://example.test/work/pricing/t1_copy", criterion: @criterion, seat: @builder)
    apply("pass_criterion", seat, "id" => @task.id, "cid" => criterion.id, "evidence" => { "kind" => kind, "value" => value })
  end

  test "passes the criterion with its evidence" do
    acknowledge
    assert pass.completed?

    @criterion.reload
    assert_equal [ "passed", @builder.id ], [ @criterion.state, @criterion.passed_by_seat_id ]
    evidence = Evidence.find_by!(criterion_id: @criterion.id)
    assert_equal [ "link", "https://example.test/work/pricing/t1_copy", @builder.id ],
      evidence.attributes.values_at("kind", "value", "attached_by_seat_id")
    passed, attached = written
    assert_equal %w[criterion.passed evidence.attached], written.map(&:type)
    assert_equal [ "criterion", @criterion.id, {} ], [ passed.subject_kind, passed.subject_id, passed.payload ]
    assert_equal [ "evidence", evidence.id, { "criterion_id" => @criterion.id, "kind" => "link" } ],
      [ attached.subject_kind, attached.subject_id, attached.payload ]
    assert_equal passed.at, @criterion.passed_at
  end

  test "a note is evidence too" do
    acknowledge
    assert pass(kind: "note", value: "See the pricing section of README.md.").completed?
  end

  test "evidence that is not https, or that carries sign-in details, is 422 invalid and writes nothing" do
    acknowledge
    [ "http://example.test/proof", "https://made-up-user:made-up-pass@example.test/proof",
      "https://example.test/proof?token=made-up-value" ].each do |value|
      assert_raises(T::Invalid, value) { pass(value: value) }
    end
    assert_equal "open", @criterion.reload.state
    assert_equal 0, Evidence.where(criterion_id: @criterion.id).count
  end

  test "while the task is held it is on_hold" do
    acknowledge
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "rounds_exceeded", facts: { round: 0 })
    end
    assert_equal "on_hold", pass.refusal.code
  end

  test "before the briefing is acknowledged it is briefing_not_acknowledged" do
    assert_equal "briefing_not_acknowledged", pass.refusal.code
  end

  test "the review criterion is 422 invalid" do
    acknowledge
    assert_raises(T::Invalid) { pass(criterion: Criterion.find_by!(task_id: @task.id, kind: "review")) }
  end

  test "after the lease expired the builder's call is lease_expired, not invalid_state (trace 10)" do
    acknowledge
    @task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.lease_expired", task: @task, payload: { wait_cause: nil })

    outcome = pass
    assert_equal "lease_expired", outcome.refusal.code
    assert_empty written
  end
end
