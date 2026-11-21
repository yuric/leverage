require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::BriefingRules (PRD L470; RC-31; milestone 4 plan RD-8): the
    # rules of a briefing, each with its version: every acting rule whose
    # fixed scope covers the task with may_apply false, and every "let the
    # checker decide" rule with may_apply true. Rules that do not act yet,
    # and rules that are off or removed, are left out.
    class BriefingRulesTest < ActiveSupport::TestCase
      include TestSupport

      def parts(task, seat = scenario.seat) = BriefingRules.call(task_id: task.id, seat_id: seat.id)

      test "all seven shipped rules are in the briefing, in shipped order" do
        expected = scenario.with_shipped_rules.map(&:id)

        result = parts(scenario.task(state: "working"))
        assert_equal expected, result.map(&:id)
        result.each do |part|
          assert_equal [ :rule, 1, false ], [ part.kind, part.version, part.may_apply ]
        end
      end

      test "a covering rule may not be skipped, a let-the-checker-decide rule may apply, others are left out" do
        covering = model_gate("task.before_submit")
        deciding = model_gate("task.before_done", scope_kind: "checker_decides")
        model_gate("task.before_submit", enabled: false)
        removed = model_gate("task.before_claim")
        removed.update!(removed_at: scenario.database_now)
        model_gate("task.before_ready", scope_kind: "named_projects", scope_values: [ scenario.project.id ])

        result = parts(scenario.task(state: "working"))
        assert_equal [ [ covering.id, false ], [ deciding.id, true ] ], result.map { |part| [ part.id, part.may_apply ] }
      end

      test "each part carries its rule's current version number" do
        rule = model_gate("task.before_submit", versions: 2)

        assert_equal [ 2 ], parts(scenario.task).map(&:version)
        RuleVersion.create!(scenario.current_version(rule).attributes.except("id", "created_at").merge("version" => 3))
        rule.update!(current_version: 3)
        assert_equal [ 3 ], parts(scenario.task).map(&:version)
      end

      test "a reviewer's briefing has the same rules (RC-31)" do
        model_gate("task.before_submit")
        task = scenario.task(state: "in_review")
        reviewer = scenario.seat(role: "reviewer")
        review = scenario.review(task, reviewer: reviewer)

        assert_equal parts(task), BriefingRules.call(task_id: task.id, seat_id: reviewer.id, review_id: review.id)
      end
    end
  end
end
