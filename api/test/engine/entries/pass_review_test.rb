require "test_helper"
require_relative "../gate_support"

# Review passes, no outward action (PRD Lifecycle L92, L510; milestone 2
# plan EN-9, EN-12): at task.before_done, review.passed and task.done are
# written, the review criterion is passed, and the verdict's tokens and
# spend write cost.reported with the review as subject and add to the
# task's spent.
class PassReviewTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  B = Leverage::Briefing

  # Records the hooks gating is asked at.
  class Recording < Leverage::Rules::Engine
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
    @reviewer = @scenario.seat(role: "reviewer")
    @task = @scenario.task(state: "in_review", builder: @builder)
    @review = @scenario.review(@task, reviewer: @reviewer)
  end

  def apply(command, params, seat = @reviewer)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def acknowledge
    apply("acknowledge_review_briefing", "id" => @review.id,
      "briefing_hash" => B.hash_for(@task, seat: @reviewer, review: @review))
  end

  def give_pass(failed: [])
    apply("pass_review", "id" => @review.id, "verdict" => "passed", "failed_criteria" => failed,
      "notes" => "Every criterion holds.", "tokens" => 1200, "spend" => 0.42)
  end

  test "passes: Done, the review criterion passed, cost reported" do
    acknowledge
    gating = Recording.new
    Leverage::Gating.implementation = gating
    assert give_pass.completed?

    @task.reload
    assert_equal [ "done", nil, @builder.id ], @task.attributes.values_at("state", "holder_seat_id", "builder_seat_id")
    assert_equal BigDecimal("0.42"), @task.spent
    @review.reload
    assert_equal [ "passed", "Every criterion holds.", [], nil, @reviewer.id ],
      @review.attributes.values_at("verdict", "notes", "failed_criteria", "lease_due_at", "reviewer_seat_id")
    review_criterion = Criterion.find_by!(task_id: @task.id, kind: "review")
    assert_equal [ "passed", @reviewer.id ], [ review_criterion.state, review_criterion.passed_by_seat_id ]

    assert_equal %w[review.passed task.done cost.reported], written.map(&:type)
    passed, done, cost = written
    assert_equal [ "review", @review.id ], [ passed.subject_kind, passed.subject_id ]
    assert_nil done.subject_kind
    assert_equal [ "review", @review.id, { "tokens" => 1200, "spend" => 0.42 } ],
      [ cost.subject_kind, cost.subject_id, cost.payload ]
    assert(written.all? { |event| event.actor_kind == "seat" && event.actor_id == @reviewer.id && event.round == 0 })
    assert_equal [ "task.before_done" ], gating.hooks
  end

  test "naming failed criteria on a pass is 422 invalid" do
    acknowledge
    assert_raises(T::Invalid) { give_pass(failed: [ Criterion.where(task_id: @task.id).first.id ]) }
  end

  test "before the reviewer's briefing is acknowledged it is briefing_not_acknowledged" do
    assert_equal "briefing_not_acknowledged", give_pass.refusal.code
    assert_empty written
  end

  test "while the task is held it is on_hold" do
    acknowledge
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: @task, reason: "owner_hold")
    end
    assert_equal "on_hold", give_pass.refusal.code
  end

  test "a reviewer that does not hold the review is not_holder" do
    outcome = apply("pass_review", { "id" => @review.id, "verdict" => "passed", "failed_criteria" => [], "notes" => "",
                                     "tokens" => 0, "spend" => 0 }, @scenario.seat(role: "reviewer"))
    assert_equal "not_holder", outcome.refusal.code
  end
end

# A pass at its gate (milestone 4 plan §2.1 rule 7, SM-6): a failed gate at
# when the review has passed is a failed review in full, at once.
class PassReviewGatedTest < ActiveSupport::TestCase
  include GateSupport

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
  end

  test "a failed gate makes the pass a failed review: the review criterion is the failed one, the check is named, no review.passed" do
    rule = app_rule("task.before_done")
    gating([ rule, { app_result: "failed" } ])
    task, review = ready_for_verdict(@builder, @reviewer)
    outcome = command("pass_review", @reviewer, pass_params(review))

    assert outcome.completed?
    assert_equal %w[check.finished review.failed criterion.reopened cost.reported], types
    failed = written.second
    review_criterion = Criterion.find_by!(task_id: task.id, kind: "review")
    assert_equal({ "failed_criterion_ids" => [ review_criterion.id ], "failed_rule_check_id" => mine(RuleCheck).sole.id,
                   "lease_seat_id" => @builder.id, "wait_cause" => nil }, failed.payload)
    assert_equal [ "failed", [ review_criterion.id ], "Made-up notes." ], review.reload.values_at(:verdict, :failed_criteria, :notes)
    assert_equal [ "working", 1, @builder.id ], task.reload.values_at(:state, :round, :holder_seat_id)
  end

  test "a pass that waits writes no verdict: the review keeps its reviewer and the task stays In review" do
    with_jobs do
      gating(custom_rule("task.before_done"))
      task, review = ready_for_verdict(@builder, @reviewer)

      assert_equal :pending, command("pass_review", @reviewer, pass_params(review)).outcome
      assert_equal [ nil, @reviewer.id ], review.reload.values_at(:verdict, :reviewer_seat_id)
      assert_equal "in_review", task.reload.state
      assert_equal %w[check.queued job.queued], types
    end
  end
end
