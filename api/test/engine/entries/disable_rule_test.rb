require "test_helper"
require_relative "rule_support"
require_relative "../../support/trace_runner"

# Entries::DisableRule (PRD L162, L166, L167, L379, L973; milestone 4 plan
# RD-45, S-5): the owner turns a rule off. Its checks in flight are
# withdrawn with their jobs, the check_error, claim_gate_failed and
# rerun_limit holds it caused close with their items, and each command
# that waited on it is gated again, so it completes if nothing else
# blocks. A rule that is off already, or removed, is invalid_state.
class DisableRuleTest < ActiveSupport::TestCase
  include RuleSupport

  Trigger = Leverage::Gating::Trigger

  setup { use_scenario }

  test "it turns the rule off with rule.disabled and writes no version (trace 18, command 38)" do
    rule = scenario.rule

    outcome, events = owner_run("disable_rule", { "id" => rule.id })

    assert_completed(outcome)
    refute rule.reload.enabled
    assert_equal 1, rule.current_version
    assert_equal [ [ "rule.disabled", {}, "owner", scenario.owner.id, "rule", rule.id ] ],
      events.map { |event| [ event.type, event.payload, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id ] }
  end

  test "Refused for every agent closes with turn_rule_off when its rule is turned off (trace 18, command 24; L166)" do
    rule = scenario.rule(hook: "task.before_claim")
    task = scenario.task(state: "ready")
    rule_hold(task, "claim_gate_failed", rule: rule)

    outcome, events = owner_run("disable_rule", { "id" => rule.id })

    assert_completed(outcome)
    assert_equal [ "rule.disabled", "hold.closed", "inbox.resolved" ], events.map(&:type)
    assert_equal({ "reason" => "claim_gate_failed", "rule_id" => rule.id, "credential_id" => nil, "lease_seat_id" => nil,
                   "wait_cause" => nil }, events[1].payload)
    assert_equal({ "choice" => "turn_rule_off" }, events[2].payload)
    assert_equal [ [ "owner", nil, task.id ] ] * 2, events.drop(1).map { |event| [ event.actor_kind, event.cause_id, event.task_id ] }
    assert_empty open_holds(task)
  end

  test "a submit waiting at the re-run limit has its row withdrawn, its hold closed and is gated again (RD-45, S-5)" do
    rule = scenario.rule(hook: "task.before_submit")
    builder = scenario.seat(role: "builder", credential: scenario.credential)
    task = scenario.task(state: "working", builder: builder)
    pending = scenario.pending_transition(task, command: "submit", requester: builder)
    held = RuleCheck.create!(workspace_id: scenario.workspace_id, task_id: task.id, rule_id: rule.id,
      rule_version_id: scenario.current_version(rule).id, hook: "task.before_submit", round: task.round,
      input_hash: "d" * 64, pending_transition_id: pending.id)
    rule_hold(task, "rerun_limit", rule: rule, check: held)
    key = new_key

    calls = recording({ Leverage::RuleChecks => :withdraw, Leverage::Jobs => :withdraw,
                        Leverage::PendingTransitions => :reenter }) do
      assert_completed(owner_command("disable_rule", { "id" => rule.id }, key: key))
    end

    assert_equal [ held.id ], calls.fetch("RuleChecks.withdraw").map { |call| call.arguments[1].id }
    assert_empty calls.fetch("Jobs.withdraw"), "the row held at the limit has no job"
    # The withdrawn row's check.finished (RuleChecks.withdraw writes it for
    # the row held at the limit too: WP8's request 2, milestone 4 plan
    # rule 11), then its hold.
    assert_equal %w[rule.disabled check.finished hold.closed inbox.resolved], written_by(key).map(&:type)
    assert_equal "withdrawn", written_by(key)[1].payload.fetch("result")
    assert_equal "rerun_limit", written_by(key)[2].payload.fetch("reason")
    reentry = calls.fetch("PendingTransitions.reenter").sole
    assert_equal [ pending.id, Trigger.new(kind: :rule_switched_off, rule_check_id: held.id) ],
      [ reentry.arguments[1].id, reentry.arguments[2] ]
  end

  test "a rule that is off already, or removed, is invalid_state and writes nothing" do
    off = scenario.rule(enabled: false)
    removed = scenario.rule
    removed.update!(removed_at: scenario.database_now)

    [ off, removed ].each do |rule|
      outcome, events = owner_run("disable_rule", { "id" => rule.id })
      assert_refused("invalid_state", outcome)
      assert_empty events
    end
    assert removed.reload.enabled
  end

  test "a rule of another workspace is 404" do
    other = Scenario.new
    other.owner

    assert_raises(T::NotFound) { owner_command("disable_rule", { "id" => other.rule.id }) }
  end

  test "trace 18's three rules are added and the submit rule, with nothing in flight, is turned off as the trace writes it" do
    name = "18-claim-gate-done-gate-and-ends"
    trace = Leverage::Contract.trace(name).deep_dup
    trace["commands"] = trace.fetch("commands").values_at(0, 25, 26, 37)
    assert_equal %w[add_rule add_rule add_rule disable_rule], trace.fetch("commands").map { |command| command.fetch("command") }

    runner = TraceRunner.new(name, trace: trace).run

    assert_empty runner.failures
  end
end
