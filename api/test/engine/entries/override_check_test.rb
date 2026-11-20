require "test_helper"
require_relative "rule_support"

# Entries::OverrideCheck (PRD L162 to L167, L380 to L383, L423, L910;
# milestone 4 plan RD-45, RD-47, RD-48): "Let it through once", for one
# failed or errored check, or one held at the re-run limit. The override
# stores who, when and why (RuleChecks.override, check.overridden), closes
# the hold it answers with its item, and gates the waiting command again,
# which completes it in place. An override of a failed check completes
# nothing by itself: the refused command is marked notify, so GET /v1/next
# tells its requester to send it again. Any other check is invalid_state.
class OverrideCheckTest < ActiveSupport::TestCase
  include RuleSupport

  Trigger = Leverage::Gating::Trigger
  REASON = "Made-up reason: checked by hand.".freeze

  setup do
    use_scenario
    @builder = scenario.seat(role: "builder", credential: scenario.credential)
    @rule = scenario.rule(hook: "task.before_submit")
    @task = scenario.task(state: "working", builder: @builder)
  end

  def override(check, key: new_key, reason: REASON)
    calls = recording({ Leverage::RuleChecks => :override, Leverage::PendingTransitions => :reenter }) do
      @outcome = owner_command("override_check", { "id" => check.id, "reason" => reason }, key: key)
    end
    [ @outcome, calls, written_by(key) ]
  end

  # The commands row a seat's refused or waiting command stored.
  def command_row(key, outcome: "refused", caller: @builder, command: "submit")
    Command.create!(workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: caller.id, key: key,
      command: command, request_hash: "e" * 64, outcome: outcome,
      refusal: ({ "code" => "blocked_by_rule", "rule_id" => @rule.id, "reason" => "Made-up." } if outcome == "refused"))
  end

  def assert_stored_override(calls, check)
    stored = calls.fetch("RuleChecks.override").sole
    assert_equal check.id, stored.arguments[1].id
    assert_equal({ user: scenario.owner, reason: REASON }, stored.keywords, "who and why; when is the command's time")
  end

  test "a failed check's override completes nothing and marks the refused submit notify (trace 17, command 11; L380)" do
    pending = scenario.pending_transition(@task, command: "submit", requester: @builder, key: "submit-1", state: "refused")
    check = scenario.rule_check(@task, rule: @rule, result: "failed", reason: "Made-up reason.", pending: pending)
    row = command_row("submit-1")
    row.update!(read_at: scenario.database_now)

    outcome, calls, events = override(check)

    assert_completed(outcome)
    assert_stored_override(calls, check)
    assert_empty calls.fetch("PendingTransitions.reenter"), "nothing waits: the submit was refused"
    assert_empty events.select { |event| event.type.start_with?("hold.", "inbox.") }
    row.reload
    assert row.notify, "GET /v1/next answers command for the refused key (L380)"
    assert_nil row.read_at
    assert_equal "refused", row.outcome
  end

  test "a failed app check refused at once marks its command notify, found by the check's own event (RE-7)" do
    rule = scenario.rule(hook: "task.before_claim", checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => 1 })
    ready = scenario.task(state: "ready")
    check = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      check = RuleCheck.create!(workspace_id: scenario.workspace_id, task_id: ready.id, rule_id: rule.id,
        rule_version_id: scenario.current_version(rule).id, hook: "task.before_claim", round: ready.round,
        subject_kind: "seat", subject_id: @builder.id, input_hash: "f" * 64, result: "failed", reason: "Made-up.")
      request = T::Request.new(command: "claim", workspace_id: scenario.workspace_id, caller_kind: "seat",
        caller_id: @builder.id, key: "claim-1", request_hash: "e" * 64, params: {})
      scenario.context(request: request).emit("check.finished", task: ready, subject: check,
        payload: { hook: check.hook, rule_id: rule.id, rule_version_id: check.rule_version_id, subject_kind: "seat",
                   subject_id: @builder.id, input_hash: check.input_hash, result: "failed", effect: nil, wait_cause: nil })
    end
    row = command_row("claim-1", command: "claim")

    outcome, = override(check)

    assert_completed(outcome)
    assert row.reload.notify
  end

  test "a failed check whose command completed is not marked: the app sends Complete contract again (RD-48)" do
    rule = scenario.rule(hook: "task.before_ready", route: "owner")
    backlog = scenario.task(state: "backlog")
    pending = scenario.pending_transition(backlog, command: "complete_contract", requester: scenario.owner,
      key: "complete-1", state: "completed")
    check = scenario.rule_check(backlog, rule: rule, result: "failed", pending: pending)
    row = Command.create!(workspace_id: scenario.workspace_id, caller_kind: "owner", caller_id: scenario.owner.id,
      key: "complete-1", command: "complete_contract", request_hash: "e" * 64, outcome: "completed")

    outcome, calls, = override(check)

    assert_completed(outcome)
    assert_stored_override(calls, check)
    refute row.reload.notify
  end

  test "an errored check's override closes check_error and completes the waiting command in place (trace 07, command 6; L382)" do
    pending = scenario.pending_transition(@task, command: "submit", requester: @builder, key: "submit-2")
    check = scenario.rule_check(@task, rule: @rule, result: "error", attempts: 2, pending: pending)
    rule_hold(@task, "check_error", rule: @rule, check: check)

    outcome, calls, events = override(check)

    assert_completed(outcome)
    assert_stored_override(calls, check)
    # check.overridden first, as RuleChecks.override writes it (trace 07,
    # event 12), then the hold it answers.
    assert_equal %w[check.overridden hold.closed inbox.resolved], events.map(&:type)
    assert_equal({ "reason" => "check_error", "rule_id" => @rule.id, "credential_id" => nil, "lease_seat_id" => nil,
                   "wait_cause" => nil }, events.second.payload)
    assert_equal({ "choice" => "override_once" }, events.last.payload)
    assert_equal [ [ "owner", scenario.owner.id ] ] * 3, events.map { |event| [ event.actor_kind, event.actor_id ] }
    reentry = calls.fetch("PendingTransitions.reenter").sole
    assert_equal [ pending.id, Trigger.new(kind: :check_overridden, rule_check_id: check.id) ],
      [ reentry.arguments[1].id, reentry.arguments[2] ]
    assert_empty open_holds(@task)
  end

  test "the check held at the re-run limit, which never ran, is let through and its command completes in place (trace 17, command 29; RD-45)" do
    pending = scenario.pending_transition(@task, command: "submit", requester: @builder, key: "submit-3")
    held = RuleCheck.create!(workspace_id: scenario.workspace_id, task_id: @task.id, rule_id: @rule.id,
      rule_version_id: scenario.current_version(@rule).id, hook: "task.before_submit", round: @task.round,
      input_hash: "a" * 64, pending_transition_id: pending.id)
    rule_hold(@task, "rerun_limit", rule: @rule, check: held)

    outcome, calls, events = override(held)

    assert_completed(outcome)
    assert_stored_override(calls, held)
    # check.overridden first (trace 17, event 52), then the hold it answers.
    assert_equal [ [ "check.overridden", nil ], [ "hold.closed", "rerun_limit" ], [ "inbox.resolved", nil ] ],
      events.map { |event| [ event.type, event.payload["reason"] ] }
    assert_equal "override_once", events.last.payload.fetch("choice")
    assert_equal [ pending.id ], calls.fetch("PendingTransitions.reenter").map { |call| call.arguments[1].id }
  end

  test "Let it through once on Refused for every agent closes that hold; the named agent's next claim goes through (RD-47)" do
    rule = scenario.rule(hook: "task.before_claim")
    ready = scenario.task(state: "ready")
    check = scenario.rule_check(ready, rule: rule, result: "failed", subject: @builder)
    rule_hold(ready, "claim_gate_failed", rule: rule, check: check)

    outcome, calls, events = override(check)

    assert_completed(outcome)
    assert_stored_override(calls, check)
    assert_equal [ [ "check.overridden", nil ], [ "hold.closed", "claim_gate_failed" ], [ "inbox.resolved", nil ] ],
      events.map { |event| [ event.type, event.payload["reason"] ] }
    assert_empty open_holds(ready)
  end

  test "Refused for every agent that names no check closes for an override of a failed claim check of its rule, and no other rule's (RD-47)" do
    rule = scenario.rule(hook: "task.before_claim")
    other = scenario.rule(hook: "task.before_claim")
    ready = scenario.task(state: "ready")
    check = scenario.rule_check(ready, rule: rule, result: "failed", subject: @builder)
    answered = rule_hold(ready, "claim_gate_failed", rule: rule)
    kept = rule_hold(ready, "claim_gate_failed", rule: other)

    outcome, _, events = override(check)

    assert_completed(outcome)
    assert answered.reload.closed_at
    assert_nil kept.reload.closed_at
    assert_equal [ rule.id ], events.select { |event| event.type == "hold.closed" }.map { |event| event.payload["rule_id"] }
  end

  test "the waiting command is not gated again while another hold stays open (rule 9)" do
    pending = scenario.pending_transition(@task, command: "submit", requester: @builder, key: "submit-4")
    check = scenario.rule_check(@task, rule: @rule, result: "error", attempts: 2, pending: pending)
    rule_hold(@task, "check_error", rule: @rule, check: check)
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(scenario.context, task: @task, reason: "owner_hold", actor_kind: "owner", actor_id: scenario.owner.id)
    end

    outcome, calls, events = override(check)

    assert_completed(outcome)
    assert_equal [ "check_error" ], events.select { |event| event.type == "hold.closed" }.map { |event| event.payload["reason"] }
    assert_empty calls.fetch("PendingTransitions.reenter")
  end

  test "a passed, not applicable, withdrawn, running or already overridden check is invalid_state and writes nothing" do
    overridden = scenario.rule_check(@task, rule: @rule, result: "failed", input_hash: "5" * 64)
    overridden.update!(overridden_at: scenario.database_now, overridden_by_user_id: scenario.owner.id, override_reason: "Made-up.")
    checks = { "passed" => scenario.rule_check(@task, rule: @rule, result: "passed", input_hash: "1" * 64),
               "not applicable" => scenario.rule_check(@task, rule: @rule, result: "not_applicable", input_hash: "2" * 64),
               "withdrawn" => scenario.rule_check(@task, rule: @rule, result: "withdrawn", input_hash: "3" * 64),
               "running" => scenario.rule_check(@task, rule: @rule, input_hash: "4" * 64),
               "overridden" => overridden }

    checks.each do |what, check|
      outcome, calls, events = override(check)
      assert_refused("invalid_state", outcome)
      assert_empty events, what
      assert_empty calls.fetch("RuleChecks.override"), what
    end
  end

  test "a check of a cancelled task is invalid_state" do
    check = scenario.rule_check(@task, rule: @rule, result: "failed")
    @task.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil)

    outcome, = override(check)

    assert_refused("invalid_state", outcome)
  end

  test "a check of another workspace is 404" do
    other = Scenario.new
    other.owner
    check = other.rule_check(other.task(state: "working", builder: other.seat(role: "builder", credential: other.credential)),
      rule: other.rule, result: "failed")

    assert_raises(T::NotFound) { owner_command("override_check", { "id" => check.id, "reason" => REASON }) }
  end
end
