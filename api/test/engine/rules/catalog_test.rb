require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::Catalog (milestone 4 plan §2.1 rule 2, RD-8; PRD L363): the
    # enabled, not removed rules bound to a hook, each with its current
    # version, shipped rules in shipped_rules.json's order and then custom
    # rules in the order they were created; an app rule whose function is
    # not built is not in the set.
    class CatalogTest < ActiveSupport::TestCase
      include TestSupport

      def keys(entries) = entries.map { |entry| entry.rule.key }

      test "the shipped rules come in the shipped order, then custom rules in the order they were added" do
        later = model_gate("task.before_ready", name: "Added first")
        scenario.with_shipped_rules
        last = model_gate("task.before_ready", name: "Added second")

        entries = Catalog.at(scenario.workspace_id, "task.before_ready")

        assert_equal [ "acceptance_criteria", "specific_details", later.key, last.key ], keys(entries)
        entries.each { |entry| assert_equal entry.rule.id, entry.version.rule_id }
      end

      test "a rule switched off, a removed rule and a rule at another hook are not in the set" do
        on = model_gate("task.before_submit")
        model_gate("task.before_submit", enabled: false)
        removed = model_gate("task.before_submit")
        removed.update!(removed_at: scenario.database_now)
        model_gate("task.before_done")

        assert_equal [ on.key ], keys(Catalog.at(scenario.workspace_id, "task.before_submit"))
      end

      test "each rule is in the set with its current version" do
        rule = model_gate("task.before_submit", versions: 3)

        entry = Catalog.at(scenario.workspace_id, "task.before_submit").sole
        assert_equal 3, entry.version.version
        assert_equal scenario.current_version(rule).id, entry.version.id
      end

      test "an app rule whose function is not built is in no set; the model approval rule is planned at its hook (RD-8)" do
        scenario.with_shipped_rules

        assert_empty Catalog.at(scenario.workspace_id, "review.failed")
        assert_empty Catalog.at(scenario.workspace_id, "cost.reported")
        assert_empty Catalog.at(scenario.workspace_id, "question.asked")
        assert_equal [ "different_provider_review" ], keys(Catalog.at(scenario.workspace_id, "review.assign"))
        assert_equal [ "orchestrator_approves_actions" ], keys(Catalog.at(scenario.workspace_id, "action.requested"))
      end

      test "another workspace's rules are not in the set" do
        Scenario.new.rule(hook: "task.before_submit")

        assert_empty Catalog.at(scenario.workspace_id, "task.before_submit")
      end

      test "the versions a request froze are found in their order, also for a rule switched off since" do
        first = model_gate("task.before_submit")
        second = model_gate("task.before_submit", versions: 2)
        ids = [ scenario.current_version(second).id, scenario.current_version(first).id ]
        first.update!(enabled: false)

        entries = Catalog.versions(ids)

        assert_equal ids, entries.map { |entry| entry.version.id }
        assert_equal [ second.id, first.id ], entries.map { |entry| entry.rule.id }
        assert_equal false, entries.last.rule.enabled
      end

      test "enabled lists the rules of every hook in the same order" do
        scenario.with_shipped_rules(off: [ "escalate_after_failed_reviews" ])
        custom = model_gate("task.before_claim")

        expected = Shipped.all.map(&:key) - [ "escalate_after_failed_reviews" ] + [ custom.key ]
        assert_equal expected, keys(Catalog.enabled(scenario.workspace_id))
      end
    end
  end
end
