require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::Reentry (PRD L367, L378-L382, L392; milestone 4 plan §2.1 rules
    # 7, 9 and 10): step 6 of How a transition is gated for a pending
    # transition, and the same for an outward action. It reads the frozen
    # versions' rows for the inputs as they are now and decides.
    class ReentryTest < ActiveSupport::TestCase
      include TestSupport

      NOTE = { "handoff_note" => "A made-up note." }.freeze

      setup do
        @builder = scenario.seat
        @task = scenario.task(state: "working", builder: @builder)
      end

      # A pending submit of the task's builder, its frozen versions those of
      # rules, and its stored request params.
      def pending_submit(*rules, params: NOTE)
        ids = rules.map { |rule| scenario.current_version(rule).id }
        scenario.pending_transition(@task, command: "submit", requester: @builder, params: params, frozen_rule_version_ids: ids)
      end

      def check(rule, pending, result: nil, input_hash: hash_for(@task, "task.before_submit", params: NOTE), **options)
        scenario.rule_check(@task, rule: rule, result: result, pending: pending, input_hash: input_hash, **options)
      end

      def reenter(pending, kind = :check_finished, rule_check = nil)
        Reentry.call(pending_transition_id: pending.id, trigger: trigger(kind, rule_check))
      end

      test "every check passed, not applicable, withdrawn or overridden completes the transition" do
        rules = Array.new(4) { model_gate("task.before_submit") }
        pending = pending_submit(*rules)
        check(rules[0], pending, result: "passed")
        check(rules[1], pending, result: "not_applicable")
        check(rules[2], pending, result: "withdrawn")
        override(check(rules[3], pending, result: "failed"))

        decision = reenter(pending)
        assert_equal :complete, decision.action
        assert_equal [ [], [], [], [] ], [ decision.failures, decision.holds_to_open, decision.checks_to_withdraw, decision.checks ]
      end

      test "a failed check refuses with the failures in the frozen order, each with its row, reason and route" do
        first = model_gate("task.before_submit", route: "owner")
        second = model_gate("task.before_submit")
        pending = pending_submit(first, second)
        two = check(second, pending, result: "failed", reason: "The second made-up reason.")
        one = check(first, pending, result: "failed", reason: "The first made-up reason.")

        decision = reenter(pending)
        assert_equal :refuse, decision.action
        assert_equal [ [ first.id, one.id, "The first made-up reason.", "owner" ], [ second.id, two.id, "The second made-up reason.", "builder" ] ],
          decision.failures.map { |failure| [ failure.rule_id, failure.rule_check_ref, failure.reason, failure.route ] }
      end

      test "a warn rule's failure does not refuse, and its running check does not keep the transition waiting" do
        blocking = model_gate("task.before_submit")
        warn = model_gate("task.before_submit", on_fail: "warn")
        other_warn = model_gate("task.before_submit", on_fail: "warn")
        pending = pending_submit(blocking, warn, other_warn)
        check(blocking, pending, result: "passed")
        check(warn, pending, result: "failed")
        check(other_warn, pending)

        assert_equal :complete, reenter(pending).action
      end

      test "a check still running keeps the transition pending" do
        rules = Array.new(2) { model_gate("task.before_submit") }
        pending = pending_submit(*rules)
        check(rules[0], pending, result: "failed")
        check(rules[1], pending)

        decision = reenter(pending)
        assert_equal :keep_pending, decision.action
        assert_empty decision.holds_to_open
      end

      test "a changed input hash cancels and withdraws the checks with no result (L367)" do
        rules = Array.new(2) { model_gate("task.before_submit") }
        pending = pending_submit(*rules)
        check(rules[0], pending, result: "passed")
        running = check(rules[1], pending)
        criterion = Criterion.find_by!(task_id: @task.id, kind: "build")
        criterion.update!(state: "passed")

        decision = reenter(pending)
        assert_equal :cancel, decision.action
        assert_equal [ running.id ], decision.checks_to_withdraw
      end

      test "an errored blocking check keeps the transition pending under one check_error hold" do
        rule = model_gate("task.before_submit")
        pending = pending_submit(rule)
        errored = check(rule, pending, result: "error")

        decision = reenter(pending, :check_timed_out, errored)
        assert_equal :keep_pending, decision.action
        hold = decision.holds_to_open.sole
        assert_equal [ "check_error", rule.id, errored.id ], [ hold.reason, hold.rule_id, hold.rule_check_id ]

        open_hold(@task, "check_error", rule: rule, check: errored)
        decision = reenter(pending, :check_timed_out, errored)
        assert_equal [ :keep_pending, [] ], [ decision.action, decision.holds_to_open ]
      end

      test "the transition's own check_error hold does not keep it waiting once its check is overridden or run again" do
        rule = model_gate("task.before_submit")
        pending = pending_submit(rule)
        errored = check(rule, pending, result: "error")
        open_hold(@task, "check_error", rule: rule, check: errored)
        override(errored)

        assert_equal :complete, reenter(pending, :check_overridden, errored).action
      end

      test "another open hold keeps a finished transition pending until it lifts (L378)" do
        rule = model_gate("task.before_submit")
        pending = pending_submit(rule)
        check(rule, pending, result: "passed")
        hold = open_hold(@task, "owner_hold")

        assert_equal :keep_pending, reenter(pending).action
        hold.update!(closed_at: scenario.database_now)
        assert_equal :complete, reenter(pending, :hold_lifted).action
      end

      test "a rule switched off or removed during a check no longer blocks (L379)" do
        off = model_gate("task.before_submit")
        removed = model_gate("task.before_submit")
        pending = pending_submit(off, removed)
        check(off, pending)
        check(removed, pending, result: "failed")
        off.update!(enabled: false)
        removed.update!(removed_at: scenario.database_now)

        assert_equal :complete, reenter(pending, :rule_switched_off).action
      end

      test "a rule edited during a check keeps its frozen version's result (L379)" do
        rule = model_gate("task.before_submit")
        pending = pending_submit(rule)
        check(rule, pending, result: "failed", reason: "A made-up reason.")
        RuleVersion.create!(scenario.current_version(rule).attributes.except("id", "created_at").merge("version" => 2))
        rule.update!(current_version: 2)

        assert_equal :refuse, reenter(pending).action
      end

      test "at ready to start the stored request is what is hashed (RE-2)" do
        rule = model_gate("task.before_ready", route: "owner")
        task = scenario.task
        params = contract_params
        ids = [ scenario.current_version(rule).id ]
        pending = scenario.pending_transition(task, command: "complete_contract", requester: scenario.owner, params: params,
          frozen_rule_version_ids: ids)
        scenario.rule_check(task, rule: rule, result: "passed", pending: pending,
          input_hash: hash_for(task, "task.before_ready", params: params))

        assert_equal :complete, Reentry.call(pending_transition_id: pending.id, trigger: trigger).action
      end

      test "at before an agent starts it an error cancels the provisional claim and opens check_error (L392)" do
        rule = model_gate("task.before_claim")
        task = scenario.task(state: "ready")
        claimant = scenario.seat
        pending = scenario.pending_transition(task, command: "claim", requester: claimant,
          frozen_rule_version_ids: [ scenario.current_version(rule).id ])
        errored = scenario.rule_check(task, rule: rule, result: "error", subject: claimant, pending: pending,
          input_hash: hash_for(task, "task.before_claim", subject: claimant))

        decision = Reentry.call(pending_transition_id: pending.id, trigger: trigger(:check_timed_out, errored))
        assert_equal :cancel, decision.action
        assert_empty decision.checks_to_withdraw, "the errored check is not queued again; the hold names it"
        assert_equal [ [ "check_error", errored.id ] ], decision.holds_to_open.map { |hold| [ hold.reason, hold.rule_check_id ] }
      end

      test "at before an agent starts it the third distinct seat's failure refuses and holds the task (SM-19)" do
        rule = model_gate("task.before_claim")
        task = scenario.task(state: "ready")
        seats = Array.new(3) { scenario.seat }
        seats.first(2).each do |seat|
          scenario.rule_check(task, rule: rule, result: "failed", subject: seat, input_hash: hash_for(task, "task.before_claim", subject: seat))
        end
        claimant = seats.last
        pending = scenario.pending_transition(task, command: "claim", requester: claimant,
          frozen_rule_version_ids: [ scenario.current_version(rule).id ])
        failed = scenario.rule_check(task, rule: rule, result: "failed", subject: claimant, pending: pending,
          input_hash: hash_for(task, "task.before_claim", subject: claimant))

        decision = Reentry.call(pending_transition_id: pending.id, trigger: trigger(:check_finished, failed))
        assert_equal :refuse, decision.action
        assert_equal [ [ "claim_gate_failed", rule.id, failed.id ] ],
          decision.holds_to_open.map { |hold| [ hold.reason, hold.rule_id, hold.rule_check_id ] }
      end

      test "at when the review has passed the subject is the review the requester holds" do
        rule = model_gate("task.before_done")
        task = scenario.task(state: "in_review")
        reviewer = scenario.seat(role: "reviewer")
        review = scenario.review(task, reviewer: reviewer)
        params = { "verdict" => "passed", "notes" => "Made-up notes." }
        pending = scenario.pending_transition(task, command: "pass_review", requester: reviewer, params: params,
          frozen_rule_version_ids: [ scenario.current_version(rule).id ])
        scenario.rule_check(task, rule: rule, result: "failed", subject: review, pending: pending,
          input_hash: hash_for(task, "task.before_done", params: params, subject: review))

        assert_equal :refuse, Reentry.call(pending_transition_id: pending.id, trigger: trigger).action
      end

      test "a transition that is no longer pending is a mistake" do
        pending = scenario.pending_transition(@task, command: "submit", requester: @builder, state: "completed")
        assert_raises(ArgumentError) { reenter(pending) }
      end
    end
  end
end
