require "test_helper"

# Submit (PRD Lifecycle L88, L120, L502; DB-13, DB-20): every builder
# criterion passed with evidence, the builder submits with a handoff note
# and the work reference at task.before_submit. The task goes In review, the
# builder lease ends, the builder is kept, the round's review row is made,
# and task.submitted records only whether the reference changed.
class SubmitTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  B = Leverage::Briefing

  # Records the hooks gating is asked at.
  class Recording < Leverage::Gating::NoRules
    attr_reader :hooks

    def initialize
      super
      @hooks = []
    end

    def evaluate(request)
      @hooks << request.hook
      super
    end
  end

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @task = @scenario.task(state: "working", builder: @builder, work_reference: "~/work/pricing-page")
    @criteria = Criterion.where(task_id: @task.id, kind: "build").order(:position).to_a
  end

  def apply(command, params, seat = @builder)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def acknowledge = apply("acknowledge_briefing", "id" => @task.id, "briefing_hash" => B.hash_for(@task, seat: @builder))

  def pass_all
    @criteria.each do |criterion|
      apply("pass_criterion", "id" => @task.id, "cid" => criterion.id,
        "evidence" => { "kind" => "link", "value" => "https://example.test/proof" })
    end
  end

  def submit(work_reference: "~/work/pricing-page")
    apply("submit", "id" => @task.id, "handoff_note" => "Done; the links show each criterion.",
      "work_reference" => work_reference)
  end

  test "submits: In review, the lease ends, the builder is kept and the round's review is made" do
    acknowledge
    pass_all
    gating = Recording.new
    Leverage::Gating.implementation = gating
    assert submit.completed?

    @task.reload
    assert_equal [ "in_review", nil, @builder.id, nil ],
      @task.attributes.values_at("state", "holder_seat_id", "builder_seat_id", "lease_due_at")
    review = Review.find_by!(task_id: @task.id, round: 0)
    assert_equal [ nil, nil, nil, "Done; the links show each criterion." ],
      review.attributes.values_at("reviewer_seat_id", "verdict", "lease_due_at", "handoff_note")
    event = written.sole
    assert_equal [ "task.submitted", "seat", @builder.id, "review", review.id, { "work_reference_changed" => false } ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.payload ]
    assert_equal [ "task.before_submit" ], gating.hooks
  end

  test "a new work reference is stored and recorded as changed, never its value" do
    acknowledge
    pass_all
    assert submit(work_reference: "~/work/pricing-page-v2").completed?
    assert_equal "~/work/pricing-page-v2", @task.reload.work_reference
    assert_equal({ "work_reference_changed" => true }, written.sole.payload)
  end

  test "a null work reference keeps the one the task has" do
    acknowledge
    pass_all
    assert submit(work_reference: nil).completed?
    assert_equal "~/work/pricing-page", @task.reload.work_reference
    assert_equal({ "work_reference_changed" => false }, written.sole.payload)
  end

  test "a builder criterion not passed, or passed with no evidence, is criteria_incomplete" do
    acknowledge
    assert_equal "criteria_incomplete", submit.refusal.code

    @criteria.each { |criterion| criterion.update!(state: "passed", passed_by_seat_id: @builder.id) }
    assert_equal "criteria_incomplete", submit.refusal.code
    assert_equal "working", @task.reload.state
  end

  test "before the briefing is acknowledged it is briefing_not_acknowledged, ahead of criteria_incomplete" do
    assert_equal "briefing_not_acknowledged", submit.refusal.code
  end

  test "while the task is held it is on_hold" do
    acknowledge
    pass_all
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "rounds_exceeded", facts: { round: 0 })
    end
    assert_equal "on_hold", submit.refusal.code
  end

  test "a work reference with sign-in details is 422 invalid" do
    acknowledge
    pass_all
    assert_raises(T::Invalid) { submit(work_reference: "https://made-up-user:made-up-pass@example.test/repo") }
    assert_equal "working", @task.reload.state
  end
end
