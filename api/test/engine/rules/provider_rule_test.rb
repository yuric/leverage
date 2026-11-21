require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::ProviderRule (PRD L441, L448, L670, L912-L913; milestone 4 plan
    # RD-50, RD-51): whether "A different provider reviews every task" is on
    # and acts, provider_allowed?, the account a seat's review would run on,
    # and whether it has one now.
    class ProviderRuleTest < ActiveSupport::TestCase
      include TestSupport

      def rule_on(enabled: true)
        scenario.with_shipped_rules(off: (enabled ? [] : [ "different_provider_review" ]))
      end

      # A task built first on claude and then, after a handoff, on codex.
      def task_built_by_handoff
        claude = scenario.credential(provider: "claude")
        codex = scenario.credential(provider: "codex")
        builder = scenario.seat(credential: claude)
        task = scenario.task(state: "in_review", builder: builder)
        scenario.append("credential.switched", task: task, subject: codex,
          payload: { from_credential_id: claude.id, model: nil, seat_id: builder.id, review_id: nil, job_id: nil })
        task
      end

      test "a reviewer whose account is of a provider the work reached by handoff is not allowed (L912)" do
        rule_on
        task = task_built_by_handoff

        refute ProviderRule.allowed?(task.id, "codex")
        refute ProviderRule.allowed?(task.id, "claude")
        assert ProviderRule.allowed?(task.id, "gemini")
        reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "codex"))
        assert ProviderRule.refuses?(reviewer, task)
      end

      test "a limited reviewer's candidate of a built provider is passed over and one of another provider is taken (L913)" do
        rule_on
        task = task_built_by_handoff
        gemini = scenario.credential(provider: "gemini")
        claude = scenario.credential(provider: "claude")
        grok = scenario.credential(provider: "grok")
        reviewer = scenario.seat(role: "reviewer", credential: gemini)
        review = scenario.review(task, reviewer: reviewer)
        at = scenario.database_now

        refute ProviderRule.allowed?(task.id, claude.provider)
        assert ProviderRule.allowed?(task.id, grok.provider)
        assert_equal grok.id, Leverage::Candidates.next_after(reviewer, review, gemini, at)&.id
      end

      test "a login and an API token of one vendor are one provider; OpenRouter is its own" do
        rule_on
        task = task_built_by_handoff

        refute ProviderRule.allowed?(task.id, "claude_api")
        refute ProviderRule.allowed?(task.id, "openai_api")
        assert ProviderRule.allowed?(task.id, "openrouter")
      end

      test "with the rule off, or removed, every provider is allowed" do
        rules = rule_on(enabled: false)
        task = task_built_by_handoff
        assert ProviderRule.allowed?(task.id, "claude")
        refute ProviderRule.on?(task)

        rules.find { |rule| rule.key == "different_provider_review" }.update!(enabled: true, removed_at: scenario.database_now)
        assert ProviderRule.allowed?(task.id, "claude")
      end

      test "with no rule at all every provider is allowed" do
        task = task_built_by_handoff

        assert ProviderRule.allowed?(task.id, "claude")
      end

      test "the provider compared is the one of the account the reviewer's run is on, or the seat's own (RD-50)" do
        codex = scenario.credential(provider: "codex")
        reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "gemini"))
        assert_equal "gemini", ProviderRule.review_provider(reviewer)

        scenario.run(reviewer, on: codex)
        assert_equal "codex", ProviderRule.review_provider(reviewer.reload)
        assert_equal "grok_api", ProviderRule.review_provider(scenario.seat(role: "reviewer", provider: "grok_api"))
      end

      test "a seat the app runs with no available account has no account to review on (RD-51)" do
        rule_on
        task = task_built_by_handoff
        gemini = scenario.credential(provider: "gemini")
        reviewer = scenario.seat(role: "reviewer", credential: gemini)
        at = scenario.database_now
        assert_equal [ "gemini", gemini.id ], ProviderRule.review_account(reviewer, at).then { |account| [ account.provider, account.credential&.id ] }
        assert ProviderRule.may_review_now?(reviewer, task, at)

        scenario.limit_credential(gemini, reset_at: at + 3600)
        assert_nil ProviderRule.review_account(reviewer.reload, at)
        refute ProviderRule.may_review_now?(reviewer, task, at)
      end

      test "a seat whose run account was limited reviews on the next available candidate, if its provider is allowed" do
        rule_on
        task = task_built_by_handoff
        gemini = scenario.credential(provider: "gemini")
        claude = scenario.credential(provider: "claude")
        reviewer = scenario.seat(role: "reviewer", credential: gemini)
        at = scenario.database_now
        scenario.limit_credential(gemini, reset_at: at + 3600)

        assert_equal claude.id, ProviderRule.review_account(reviewer.reload, at).credential.id
        refute ProviderRule.may_review_now?(reviewer, task, at), "its next account is of a provider that built the task"
      end

      test "a seat that connects on its own reviews on its own provider" do
        rule_on
        task = task_built_by_handoff
        own = scenario.seat(role: "reviewer", provider: "gemini")
        built = scenario.seat(role: "reviewer", provider: "codex")
        at = scenario.database_now

        assert_equal [ "gemini", nil ], ProviderRule.review_account(own, at).then { |account| [ account.provider, account.credential ] }
        assert ProviderRule.may_review_now?(own, task, at)
        refute ProviderRule.may_review_now?(built, task, at)
      end
    end
  end
end
