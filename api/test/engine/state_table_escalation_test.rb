require "test_helper"
require_relative "gate_support"
require_relative "entries/jobs_support"

# AP-24 and AP-25: the escalation row changes who may claim the rework.
class StateTableEscalationTest < ActionDispatch::IntegrationTest
  include JobsSupport
  include GateSupport

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder", strength_rank: 1)
    @reviewer = @scenario.seat(role: "reviewer")
  end

  escalation = StateTableCases.for(%w[fail_review]).find { |row| row.guard == %w[escalates] }

  test "state table: #{escalation.name}" do
    stronger = @scenario.seat(role: "builder", strength_rank: 3)
    gating([ escalation_rule, { effect: "escalated" } ])
    task, review = ready_for_verdict(@builder, @reviewer)
    before = mine(Event).maximum(:at)

    answering(Leverage::WorkspaceLock, :clock, -> { before - 1 }) do
      with_reassignment_projection do
        assert command(escalation.command, @reviewer, fail_params(review, task)).completed?
      end
    end

    assert_equal [ "check.finished", *escalation.events, "cost.reported" ], types
    policy, failed, reopened, reassigned = written
    assert_equal [ escalation.to, nil, nil, nil, 2, 1 ],
      task.reload.values_at(:state, :holder_seat_id, :builder_seat_id, :lease_due_at, :minimum_strength_rank, :round)
    assert_equal [ "applied", "escalated", review.id ], policy.payload.values_at("result", "effect", "subject_id")
    assert_equal "failed", review.reload.verdict
    assert_equal "open", Criterion.find(reopened.subject_id).state
    assert_equal [ nil, nil ], failed.payload.values_at("lease_seat_id", "wait_cause")
    assert_equal [ failed.id, 2, nil ], [ reassigned.cause_id, *reassigned.payload.values_at("minimum_strength_rank", "wait_cause") ]
    assert_operator policy.at, :>, before
    assert_equal [ 0 ], written.map(&:round).uniq
    assert_equal [ policy.at ], written.map(&:effective_at).uniq
    assert_equal [ "none", "not_eligible" ], [ next_kind(@builder), claim_refusal(@builder) ]
    assert_equal "task", next_kind(stronger)
    assert command("claim", stronger).completed?
    assert_equal stronger.id, task.reload.holder_seat_id
  end

  test "a stronger General seat that never reviewed the task causes the escalation row" do
    @scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped", parameters: { "threshold" => 1 })
    @scenario.seat(role: "general", strength_rank: 2)
    task, review = ready_for_verdict(@builder, @reviewer)

    assert command("fail_review", @reviewer, fail_params(review, task)).completed?

    assert_equal [ "ready", nil, 2 ], task.reload.values_at(:state, :holder_seat_id, :minimum_strength_rank)
    assert_includes types, "task.reassigned"
  end

  test "an applied escalation after a before-done gate failure takes the same row" do
    @scenario.seat(role: "builder", strength_rank: 2)
    before_done = app_rule("task.before_done")
    gating([ before_done, { app_result: "failed" } ], [ escalation_rule, { effect: "escalated" } ])
    task, review = ready_for_verdict(@builder, @reviewer)

    with_reassignment_projection do
      assert command("pass_review", @reviewer, pass_params(review)).completed?
    end

    assert_equal [ "check.finished", "check.finished", *escalation.events, "cost.reported" ], types
    assert_equal [ "failed", written.first.subject_id ], review.reload.values_at(:verdict, :failed_rule_check_id)
    assert_equal "review", Criterion.find(written[3].subject_id).kind
    assert_equal [ "ready", 2 ], task.reload.values_at(:state, :minimum_strength_rank)
  end

  test "with no escalation effect a failed review returns to the previous free builder" do
    gating(escalation_rule)
    task, review = ready_for_verdict(@builder, @reviewer)

    assert command("fail_review", @reviewer, fail_params(review, task)).completed?

    assert_equal %w[review.failed criterion.reopened cost.reported], types
    assert_equal [ "working", @builder.id, nil ], task.reload.values_at(:state, :holder_seat_id, :minimum_strength_rank)
  end

  test "claim and next both leave out a higher minimum and a task the claim filter excludes" do
    stronger = @scenario.seat(role: "builder", strength_rank: 2)
    ranked = @scenario.task(state: "ready")
    ranked.update_columns(minimum_strength_rank: 2)
    filtered = @scenario.task(state: "ready")
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(claim_checks: [
      { task_id: filtered.id, seat_id: @builder.id, result: "failed", current: true }
    ])

    assert_equal [ "none", "not_eligible" ], [ next_kind(@builder), claim_refusal(@builder) ]
    assert_equal "task", next_kind(stronger)
    assert_equal "ready", filtered.reload.state
  end

  test "a builder an approved action waits for cannot claim another Ready task" do
    ready = @scenario.task(state: "ready")
    assert_equal "task", next_kind(@builder)
    login = @scenario.credential
    @scenario.limit_credential(login)
    @scenario.seat(role: "builder", credential: login)
    finishing = @scenario.finishing_task(builder: @builder, holder: false,
      actions: [ { kind: "publish", description: "Write a made-up line.", state: "approved" } ])
    waiting = ->(seat) { seat.id == @builder.id ? [ finishing ] : [] }

    answering(Leverage::Finishing, :waiting_for, waiting) do
      refute_equal "task", next_kind(@builder)
      assert_equal "not_eligible", claim_refusal(@builder)
      assert_equal "credential_limit", Leverage::Candidates.wait_cause(ready, @scenario.database_now)
    end

    assert_equal "ready", ready.reload.state
  end

  private

  def escalation_rule
    @scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped")
  end

  def fail_params(review, task)
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    pass_params(review).merge("verdict" => "failed", "failed_criteria" => [ criterion.id ])
  end

  def next_kind(seat)
    get "/v1/next", headers: seat_headers(seat)
    assert_response :ok
    response.parsed_body.fetch("kind")
  end

  def claim_refusal(seat)
    post "/v1/tasks/claim-next", params: "{}", headers: seat_headers(seat).merge(
      "Content-Type" => "application/json", "Idempotency-Key" => new_key
    )
    assert_response :conflict
    response.parsed_body.dig("refusal", "code")
  end

  def seat_headers(seat) = { "Authorization" => "Bearer #{@scenario.token_for(seat)}" }

  # WP4 owns the task.reassigned step projection. Until that event is
  # handled, exercise the event writer with just its projection stubbed.
  def with_reassignment_projection(&)
    return yield if Leverage::Steps::HANDLED.include?("task.reassigned")

    original = Leverage::Steps.method(:on_event)
    projecting = ->(ctx, event) { original.call(ctx, event) unless event.type == "task.reassigned" }
    answering(Leverage::Steps, :on_event, projecting, &)
  end
end
