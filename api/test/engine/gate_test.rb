require "test_helper"
require_relative "gate_support"

# Test 4, gating (PRD L838 to L848's fourth test; milestone 4 plan RD-9,
# RT-4): with the production gating, the rules engine, no command commits
# the move a gate guards while an enabled blocking gate in its frozen set
# has not passed. Each of the four gate hooks a task can reach is tested
# with an app gate and with a model gate, on and off; and the one policy
# whose rule acts in this milestone, the provider rule at review.assign,
# on and off. The other hooks are named here as tested in milestone 5,
# from the same list as RD-8.
#
# Every rule here is a custom rule written as rows (Scenario#rule), so the
# app gate is the built function minimum_criteria_count at the hook under
# test, and the model gate is the orchestrator's; the orchestrator is a
# seat that connects on its own and claims its job through claim_job.
class GateTest < ActiveSupport::TestCase
  include GateSupport

  # The move each gate hook guards.
  MOVES = { "task.before_ready" => "task.ready", "task.before_claim" => "task.claimed",
            "task.before_submit" => "task.submitted", "task.before_done" => "review.passed" }.freeze

  # The hooks whose rules act only from milestone 5 (RD-8, RD-9): tested
  # on and off then.
  LATER = %w[action.requested review.failed question.asked cost.reported].freeze

  setup do
    @scenario = Scenario.new
  end

  test "the production gating, set on every prepare, is the rules engine" do
    Leverage::Gating.implementation = nil
    Rails.application.reloader.prepare!

    assert_instance_of Leverage::Rules::Engine, Leverage::Gating.implementation
    refute defined?(Leverage::Gating::NoRules), "NoRules is deleted with the switch (milestone 4 plan §2.1)"
  end

  test "every hook is tested here or named as milestone 5's" do
    assert_equal Leverage::Contract.registry.fetch("hooks").sort, (MOVES.keys + %w[review.assign] + LATER).sort
  end

  MOVES.each_key do |hook|
    test "#{hook}: a failing app gate stops the move, a passing one lets it through, and off it is not asked" do
      failing = app_gate(hook, 5)
      task, outcome = attempt(hook)
      refute_moved hook
      check = mine(RuleCheck).find_by!(rule_id: failing.id, task_id: task.id)
      assert_equal "failed", check.result
      assert_failed_effect(hook, outcome, failing, task)

      @scenario = Scenario.new
      passing = app_gate(hook, 1)
      task, outcome = attempt(hook)
      assert_equal :completed, outcome.outcome, hook
      assert_moved hook
      assert_equal "passed", mine(RuleCheck).find_by!(rule_id: passing.id, task_id: task.id).result

      @scenario = Scenario.new
      off = app_gate(hook, 5, enabled: false)
      _, outcome = attempt(hook)
      assert_equal :completed, outcome.outcome, hook
      assert_moved hook
      refute mine(RuleCheck).exists?(rule_id: off.id)
    end

    test "#{hook}: a model gate waits, a failed check never lets the move commit, a passed one completes it" do
      failing = custom_rule(hook)
      task, outcome = attempt(hook)
      assert_equal :pending, outcome.outcome, hook
      refute_moved hook
      answer_check(failing, task, "failed")
      refute_moved hook
      assert_equal "failed", mine(RuleCheck).find_by!(rule_id: failing.id, task_id: task.id).result

      @scenario = Scenario.new
      passing = custom_rule(hook)
      task, outcome = attempt(hook)
      assert_equal :pending, outcome.outcome, hook
      refute_moved hook
      answer_check(passing, task, "passed")
      assert_moved hook

      @scenario = Scenario.new
      off = custom_rule(hook, enabled: false)
      _, outcome = attempt(hook)
      assert_equal :completed, outcome.outcome, hook
      assert_moved hook
      refute mine(RuleCheck).exists?(rule_id: off.id)
      refute mine(Job).exists?
    end
  end

  test "review.assign: on, a reviewer on a provider that built the task is refused and the refusal recorded; off, it claims" do
    rule = @scenario.rule(key: "different_provider_review", origin: "shipped")
    review = review_built_on("claude")
    same = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "claude"))

    outcome = command("claim_review", same, {})
    assert_equal "not_eligible", outcome.refusal&.code
    assert_nil review.reload.reviewer_seat_id
    applied = mine(RuleCheck).find_by!(rule_id: rule.id, hook: "review.assign", subject_id: same.id)
    assert_equal %w[applied refused], [ applied.result, applied.effect ]

    other = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
    assert_equal :completed, command("claim_review", other, {}).outcome
    assert_equal other.id, review.reload.reviewer_seat_id

    @scenario = Scenario.new
    @scenario.rule(key: "different_provider_review", origin: "shipped", enabled: false)
    review = review_built_on("claude")
    same = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "claude"))
    assert_equal :completed, command("claim_review", same, {}).outcome
    assert_equal same.id, review.reload.reviewer_seat_id
    refute mine(RuleCheck).exists?
  end

  private

  # Sends the command whose hook is under test, on a task built to just
  # before it. Returns [task, outcome].
  def attempt(hook)
    case hook
    when "task.before_ready"
      task = @scenario.task(state: "backlog")
      [ task, command("complete_contract", @scenario.owner, contract_params(task)) ]
    when "task.before_claim"
      task = @scenario.task(state: "ready")
      [ task, command("claim", @scenario.seat, {}) ]
    when "task.before_submit"
      builder = @scenario.seat
      task = ready_to_submit(builder)
      [ task, command("submit", builder, submit_params(task)) ]
    when "task.before_done"
      reviewer = @scenario.seat(role: "reviewer", provider: "codex")
      task, review = ready_for_verdict(@scenario.seat, reviewer)
      [ task, command("pass_review", reviewer, pass_params(review)) ]
    end
  end

  # What a failed gate does at each hook (hooks.json failed_gate).
  def assert_failed_effect(hook, outcome, rule, task)
    case hook
    when "task.before_ready"
      assert_equal :completed, outcome.outcome
      assert_equal "backlog", task.reload.state
      assert mine(Hold).exists?(task_id: task.id, reason: "contract_incomplete", closed_at: nil)
    when "task.before_done"
      assert_equal :completed, outcome.outcome
      assert mine(Event).exists?(task_id: task.id, type: "review.failed")
    else
      assert_equal %w[blocked_by_rule], [ outcome.refusal&.code ]
      assert_equal rule.id, outcome.refusal.rule_id
    end
  end

  # The orchestrator claims the check's job and answers it.
  def answer_check(rule, task, result)
    orchestrator = @scenario.orchestrator
    check = mine(RuleCheck).find_by!(rule_id: rule.id, task_id: task.id)
    claimed = command("claim_job", orchestrator, {})
    assert_equal :completed, claimed.outcome
    job = mine(Job).find_by!(target_id: check.id, state: "claimed")
    answered = command("submit_job_result", orchestrator, { "id" => job.id,
      "result" => { "result" => result, "reason" => "A made-up reason." }, "tokens" => 10, "spend" => 0 })
    assert_equal :completed, answered.outcome
  end

  # A blocking app gate at hook: at least minimum build criteria (the
  # tasks here have one).
  def app_gate(hook, minimum, enabled: true)
    @scenario.rule(hook: hook, checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => minimum }, enabled: enabled)
  end

  # An In review task whose builder ran on a login of provider.
  def review_built_on(provider)
    builder = @scenario.seat(credential: @scenario.credential(provider: provider))
    task = @scenario.task(state: "in_review", builder: builder)
    Review.find_by!(task_id: task.id, verdict: nil)
  end

  def moved?(hook) = mine(Event).exists?(type: MOVES.fetch(hook))

  def assert_moved(hook) = assert(moved?(hook), "#{MOVES.fetch(hook)} was not written (#{hook})")

  def refute_moved(hook) = refute(moved?(hook), "#{MOVES.fetch(hook)} was written past the gate (#{hook})")
end
