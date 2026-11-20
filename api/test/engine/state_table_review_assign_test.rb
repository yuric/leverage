require "test_helper"
require_relative "provider_world"
require_relative "entries/call_spy"

# The state rows at review.assign and the item SM-42 keeps (milestone 4
# plan WP9; contract state_machine.json claim_review, submit and
# connect_seat; RC-50, RD-11, RD-12, RE-7):
#
# - claim_review: claim-next skips a review the provider rule keeps from
#   the seat, and for each review it skips asks gating at review.assign
#   about that seat and has the plan written (RuleChecks.write: the applied
#   row with effect refused and its check.finished, the side event of the
#   row), once per reviewer and round, also when nothing is left and the
#   claim is refused not_eligible.
# - Trace 02's submit and connect_seat, event for event: the item opens at
#   submit, caused by task.submitted, and closes when a reviewer of another
#   provider connects.
#
# RuleChecks.write is WP4's and does nothing yet, so the tests hold the
# call and its arguments; gating is a Gating::StandIn world (ProviderWorld)
# whose answers stand for the engine's.
class StateTableReviewAssignTest < ActiveSupport::TestCase
  include CallSpy

  T = Leverage::Transitions
  HOOK = "review.assign".freeze

  setup do
    @scenario = Scenario.new
    @rule = @scenario.with_shipped_rules.find { |rule| rule.key == "different_provider_review" }
    @claude = @scenario.credential(provider: "claude")
    @builder = @scenario.seat(role: "builder", credential: @claude)
    @task = @scenario.task(state: "in_review", builder: @builder)
    @review = Review.find_by!(task_id: @task.id)
    Leverage::Gating.implementation = ProviderWorld.for(@rule)
  end

  def reviewer(provider)
    @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: provider))
  end

  def command(caller, command, params = {}, key: "key-#{SecureRandom.hex(6)}")
    kind = caller.is_a?(Seat) ? "seat" : "owner"
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: kind, caller_id: caller.id,
      key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  # The RuleChecks.write calls the block made.
  def writes(&) = spy_on(Leverage::RuleChecks, :write, &)

  def seat_hash(seat) = Leverage::Gating.input_hash(hook: HOOK, inputs: { "seat_id" => seat.id })

  # A task In review built on the given login, its review made at seconds
  # before now, so the order of reviews is fixed.
  def waiting_task(credential, seconds_ago)
    task = @scenario.task(state: "in_review", builder: @scenario.seat(role: "builder", credential: credential))
    Review.where(task_id: task.id).update_all(created_at: @scenario.database_now - seconds_ago)
    task
  end

  # --- claim_review: the review.assign row ---------------------------------------

  test "claim-next skips a review the rule keeps from the seat, has its applied row written, and is refused not_eligible (RC-50, RD-12)" do
    seat = reviewer("claude")
    key = "key-#{SecureRandom.hex(6)}"
    outcome = nil
    call = writes { outcome = command(seat, "claim_review", key: key) }.sole

    assert_equal "not_eligible", outcome.refusal.code
    ctx, evaluation = call.arguments
    assert_equal [ key, seat.id ], [ ctx.request.key, ctx.request.caller_id ]
    assert_equal @task.id, call.keywords.fetch(:task).id
    check = evaluation.checks.sole
    assert_equal [ @rule.id, HOOK, 0, "seat", seat.id, "app", "applied", "refused", seat_hash(seat) ],
      [ check.rule_id, check.hook, check.round, check.subject_kind, check.subject_id, check.checker, check.result, check.effect,
        check.input_hash ]
    assert_nil @review.reload.reviewer_seat_id
    assert_equal "refused", Command.find_by!(workspace_id: @scenario.workspace_id, key: key).outcome,
      "the refused claim commits, with what it wrote (RE-7)"
  end

  test "a second try writes nothing: the row is one per reviewer and round (RD-12)" do
    seat = reviewer("claude")
    @scenario.rule_check(@task, rule: @rule, result: "applied", effect: "refused", hook: HOOK, subject: seat,
      input_hash: seat_hash(seat))

    asked = spy_on(Leverage::Gating, :evaluate) do
      assert_empty writes { assert_equal "not_eligible", command(seat, "claim_review").refusal.code }
    end
    assert_empty asked

    @review.update!(verdict: "failed")
    @task.update!(round: 1)
    Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: 1)
    assert_equal [ 1 ], writes { command(seat, "claim_review") }.map { |call| call.arguments[1].checks.sole.round },
      "a new round is a new wait"
  end

  test "a review the seat may take is claimed with no row; a refused review before it gets its row, one after it none" do
    seat = reviewer("claude")
    @review.update_columns(created_at: @scenario.database_now)
    older = waiting_task(@scenario.credential(provider: "claude"), 300)
    allowed = waiting_task(@scenario.credential(provider: "codex"), 200)
    waiting_task(@scenario.credential(provider: "claude"), 100)

    outcome = nil
    calls = writes { outcome = command(seat, "claim_review") }
    assert outcome.completed?
    assert_equal seat.id, Review.find_by!(task_id: allowed.id).reviewer_seat_id
    assert_equal [ older.id ], calls.map { |call| call.keywords.fetch(:task).id }
  end

  test "a past holder, a held task and a seat that may not claim get no row" do
    seat = reviewer("claude")
    @scenario.append("task.claimed", task: @task, actor_kind: "seat", actor_id: seat.id,
      payload: { seat_id: seat.id, credential_id: seat.credential_id, model: nil })
    assert_empty writes { assert_equal "not_eligible", command(seat, "claim_review").refusal.code }, "a past holder"

    other = reviewer("claude")
    @scenario.hold(@task, reason: "owner_hold")
    assert_empty writes { assert_equal "not_eligible", command(other, "claim_review").refusal.code }, "a held task"

    busy = reviewer("claude")
    @scenario.review(@scenario.task(state: "in_review", builder: @scenario.seat(role: "builder", provider: "grok")),
      reviewer: busy)
    assert_empty writes { assert_equal "not_eligible", command(busy, "claim_review").refusal.code }, "holds a review"
  end

  test "with the rule off nothing is skipped and nothing written" do
    seat = reviewer("claude")
    Leverage::Gating.implementation = ProviderWorld.new(rule_id: nil)
    outcome = nil
    assert_empty writes { outcome = command(seat, "claim_review") }
    assert outcome.completed?
  end

  # --- Trace 02's submit and connect_seat, event for event -------------------------

  FIELDS = %w[type actor_kind actor_id project_id task_id round subject_kind subject_id cause_id command_id payload].freeze

  def trace_events(index) = Leverage::Contract.trace("02-failed-review-rework").fetch("commands").fetch(index)

  # Each symbol of the trace's events bound to this test's id.
  def assert_events(expected, written, symbols)
    assert_equal expected.map { |event| event["type"] }, written.map(&:type)
    expected.zip(written).each do |event, row|
      FIELDS.each do |field|
        expected_value = bind(event[field], symbols)
        actual = row.public_send(field)
        expected_value.nil? ? assert_nil(actual, "#{event["ref"]} #{field}") : assert_equal(expected_value, actual, "#{event["ref"]} #{field}")
      end
      assert_equal row.at, row.effective_at, event["ref"] if event["effective_at"] == event["at"]
    end
  end

  def bind(value, symbols)
    case value
    when Hash then value.transform_values { |item| bind(item, symbols) }
    when Array then value.map { |item| bind(item, symbols) }
    when /\A[$@]/ then symbols.fetch(value)
    else value
    end
  end

  test "trace 02: submit opens the item, caused by task.submitted; connecting a Codex reviewer resolves it" do
    project = @scenario.project
    claude_b = @scenario.credential(provider: "claude")
    codex_r = @scenario.credential(provider: "codex", model: "codex-model-1")
    @scenario.seat(role: "reviewer", credential: claude_b)
    task = @scenario.task(state: "working", builder: @builder, project: project)
    assert command(@builder, "acknowledge_briefing",
      { "id" => task.id, "briefing_hash" => Leverage::Briefing.hash_for(task, seat: @builder) }).completed?
    Criterion.where(task_id: task.id, kind: "build").find_each do |criterion|
      assert command(@builder, "pass_criterion", { "id" => task.id, "cid" => criterion.id,
        "evidence" => { "kind" => "link", "value" => "https://example.test/work/t1/build" } }).completed?
    end

    submit = trace_events(6)
    before = @scenario.workspace.reload.last_seq
    assert command(@builder, "submit", submit.fetch("body").merge("id" => task.id), key: "key-submit").completed?
    written = Event.where(workspace_id: @scenario.workspace_id).where("seq > ?", before).order(:seq).to_a
    item = InboxItem.find_by!(workspace_id: @scenario.workspace_id, kind: "no_reviewer_eligible", state: "open")
    review = Review.find_by!(task_id: task.id)
    symbols = { "$seat:builder" => @builder.id, "$project:site" => project.id, "$task:1" => task.id,
                "$review:t1_r0" => review.id, "$key:t1_submit_310" => "key-submit", "$inbox:t1_no_reviewer" => item.id,
                "@event:10" => written.first&.id }
    assert_events submit.dig("expect", "events"), written, symbols
    assert_equal({ "review_id" => review.id, "rule_id" => @rule.id }, item.facts)

    connect = trace_events(7)
    body = connect.fetch("body").merge("credential_id" => codex_r.id)
    before = @scenario.workspace.reload.last_seq
    outcome = command(@scenario.owner, "connect_seat", body, key: "key-connect")
    written = Event.where(workspace_id: @scenario.workspace_id).where("seq > ?", before).order(:seq).to_a
    symbols.merge!("$user:owner" => @scenario.owner.id, "$seat:codex_reviewer" => outcome.result&.fetch("seat_id"),
      "$key:connect_codex_reviewer" => "key-connect")
    assert_events connect.dig("expect", "events"), written, symbols
    assert_equal "resolved", item.reload.state
  end
end
