require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::ClaimFilter (RC-19, RC-50; milestone 4 plan RD-12): what
    # claim-next skips for one seat. Tasks: those this seat failed a
    # blocking task.before_claim gate on, on the current inputs, and not
    # overridden. Reviews: those the provider rule keeps from this seat.
    # GET /v1/next and claim-next both ask it, through Eligibility.
    class ClaimFilterTest < ActiveSupport::TestCase
      include TestSupport

      def filter(seat, kind) = ClaimFilter.call(seat_id: seat.id, kind: kind)

      def claim_check(task, seat, rule, result: "failed", contract_version: task.contract_version, round: task.round)
        hash = Leverage::Gating.input_hash(hook: "task.before_claim",
          inputs: { "contract_version" => contract_version, "seat_id" => seat.id })
        scenario.rule_check(task, rule: rule, result: result, subject: seat, input_hash: hash, round: round)
      end

      test "a task this seat failed on the current inputs is skipped; an overridden failure is not" do
        rule = model_gate("task.before_claim")
        seat = scenario.seat
        failed = scenario.task(state: "ready")
        overridden = scenario.task(state: "ready")
        claim_check(failed, seat, rule)
        override(claim_check(overridden, seat, rule))

        assert_equal [ failed.id ], filter(seat, :task).excluded_task_ids
        assert_empty filter(seat, :task).excluded_review_ids
      end

      test "another seat's failure, an older contract version, another round, a passed or errored check skip nothing" do
        rule = model_gate("task.before_claim")
        seat = scenario.seat
        task = scenario.task(state: "ready")
        claim_check(task, scenario.seat, rule)
        claim_check(task, seat, rule, contract_version: 0)
        claim_check(task, seat, rule, round: 1)
        claim_check(scenario.task(state: "ready"), seat, rule, result: "passed")
        claim_check(scenario.task(state: "ready"), seat, rule, result: "error")

        assert_empty filter(seat, :task).excluded_task_ids
      end

      test "a failure of a rule now off, saved since, or that only warns skips nothing" do
        off = model_gate("task.before_claim")
        saved = model_gate("task.before_claim")
        warn = model_gate("task.before_claim", on_fail: "warn")
        seat = scenario.seat
        [ off, saved, warn ].each { |rule| claim_check(scenario.task(state: "ready"), seat, rule) }
        off.update!(enabled: false)
        RuleVersion.create!(scenario.current_version(saved).attributes.except("id", "created_at").merge("version" => 2))
        saved.update!(current_version: 2)

        assert_empty filter(seat, :task).excluded_task_ids
      end

      test "a review the provider rule keeps from this seat is skipped, by next and by claim-next alike (RD-12)" do
        scenario.with_shipped_rules
        claude_task = scenario.task(state: "in_review", builder: scenario.seat(credential: scenario.credential(provider: "claude")))
        codex_task = scenario.task(state: "in_review", builder: scenario.seat(credential: scenario.credential(provider: "codex")))
        reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude"))
        claude_review = Review.find_by!(task_id: claude_task.id)
        codex_review = Review.find_by!(task_id: codex_task.id)

        assert_equal [ claude_review.id ], filter(reviewer, :review).excluded_review_ids
        assert_empty filter(reviewer, :review).excluded_task_ids
        assert_equal codex_review.id, Leverage::Eligibility.next_review(reviewer, at: scenario.database_now)&.id
      end

      test "with the provider rule off no review is skipped" do
        scenario.with_shipped_rules(off: [ "different_provider_review" ])
        scenario.task(state: "in_review", builder: scenario.seat(credential: scenario.credential(provider: "claude")))
        reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude"))

        assert_empty filter(reviewer, :review).excluded_review_ids
      end

      test "only tasks of covered projects at or over budget are skipped when the rule is on" do
        rule = scenario.rule(key: "project_budget_pause", origin: "shipped")
        seat = scenario.seat
        at_budget = scenario.project(budget: 2, spent: 2)
        over_budget = scenario.project(budget: 2, spent: 3)
        under_budget = scenario.project(budget: 2, spent: 1)
        no_budget = scenario.project(spent: 5)
        at = scenario.task(state: "ready", project: at_budget)
        over = scenario.task(state: "ready", project: over_budget)
        [ under_budget, no_budget, nil ].each { |project| scenario.task(state: "ready", project: project) }

        assert_equal [ at.id, over.id ].sort, filter(seat, :task).excluded_task_ids.sort
        rule.update!(enabled: false)
        assert_empty filter(seat, :task).excluded_task_ids
      end

      test "the project budget claim filter observes the active rule's scope" do
        named = scenario.project(budget: 1, spent: 1)
        other = scenario.project(budget: 1, spent: 1)
        scenario.rule(key: "project_budget_pause", origin: "shipped", scope_kind: "named_projects",
          scope_values: [ named.id ])
        allowed = scenario.task(state: "ready", project: named)
        scenario.task(state: "ready", project: other)

        assert_equal [ allowed.id ], filter(scenario.seat, :task).excluded_task_ids
      end

      test "it filters only tasks and reviews" do
        assert_raises(ArgumentError) { ClaimFilter.call(seat_id: scenario.seat.id, kind: :job) }
      end
    end
  end
end
