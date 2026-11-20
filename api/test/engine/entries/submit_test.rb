require "test_helper"
require_relative "../gate_support"

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

  # milestone 3 plan HE-25 (ii), WP6's request 1: an edit from In review
  # keeps the round and its review row (no verdict, no reviewer), so the
  # next submit in that round takes that row again rather than making a
  # second one for the same round.
  test "after an edit from In review, the next submit in the round takes the round's open review again" do
    acknowledge
    pass_all
    assert submit.completed?
    review = Review.find_by!(task_id: @task.id, verdict: nil)
    contract = { "id" => @task.id, "title" => @task.title, "goal" => @task.goal, "details" => nil,
                 "criteria" => [ { "text" => "Made-up criterion 1, changed.", "kind" => "build" },
                                 { "text" => "Made-up criterion 2.", "kind" => "review" } ],
                 "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }
    owner = ->(command) do
      T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "owner",
        caller_id: @scenario.owner.id, key: "key-#{SecureRandom.hex(6)}", request_hash: "a" * 64, params: contract))
    end
    assert owner.call("edit_contract").completed?
    assert owner.call("complete_contract").completed?
    assert apply("claim", {}).completed?
    @task.reload
    @criteria = Criterion.where(task_id: @task.id, kind: "build", removed_at: nil).order(:position).to_a
    acknowledge
    pass_all

    outcome = submit
    assert outcome.completed?, outcome.refusal&.code
    assert_equal [ review.id ], Review.where(task_id: @task.id).pluck(:id)
    assert_equal "Done; the links show each criterion.", review.reload.handoff_note
    assert_equal review.id, written.sole.subject_id
    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
  end
end

# Submit at its gate (milestone 4 plan §2.1 rules 6 and 7, RE-2, RE-7).
class SubmitGatedTest < ActiveSupport::TestCase
  include GateSupport

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
  end

  test "a submit that waits keeps its request whole; the task stays Working, held by the builder" do
    with_jobs do
      gating(custom_rule("task.before_submit"))
      task = ready_to_submit(@builder)
      params = submit_params(task, note: "Made-up note that names the tests.")

      assert_equal :pending, command("submit", @builder, params).outcome
      assert_equal params, Leverage::PendingTransitions.of(task).params
      assert_equal [ "working", @builder.id ], task.reload.values_at(:state, :holder_seat_id)
      assert_not Review.exists?(task_id: task.id)
    end
  end

  test "a refused submit commits its failed check row and check.finished under its key (RE-7)" do
    rule = app_rule("task.before_submit")
    gating([ rule, { app_result: "failed", reason: "Made-up reason." } ])
    task = ready_to_submit(@builder)
    outcome = command("submit", @builder, submit_params(task))

    assert outcome.refused?
    assert_equal [ "failed", "Made-up reason." ], mine(RuleCheck).sole.values_at(:result, :reason)
    assert_equal [ [ "check.finished", "seat", @builder.id ] ], written.map { |event| [ event.type, event.actor_kind, event.actor_id ] }
    assert_equal "refused", Command.find_by!(key: @key).outcome
  end
end
