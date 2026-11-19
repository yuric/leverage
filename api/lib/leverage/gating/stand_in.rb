module Leverage
  module Gating
    # A gating implementation with no database. It decides from an in-memory
    # world by the PRD's gating rules, so the transition function and the
    # tests can run before track B's implementation exists, and the
    # conformance suite is proven on two implementations (rule AR-001).
    #
    # The world, all keys optional:
    #   rules:          [{id:, version_id:, version:, hook:, kind:, checker:,
    #                     on_fail:, route:, enabled:, scope:, app_result:, effect:}]
    #                   scope is "covers", "not_covered" or "checker_decides";
    #                   app_result is what an app checker returns ("passed" by
    #                   default); effect is what an app policy chooses.
    #   transitions:    {pending_transition_id => {task_id:, held:,
    #                     inputs_changed:, checks: [{id:, rule_id:, result:, overridden:}]}}
    #   actions:        {action_id => {request:, checks: [{id:, rule_id:, result:, overridden:}]}}
    #                   the Request evaluated at action.requested and the
    #                   action's gate checks, for reenter_action.
    #   claim_checks:   [{task_id:, seat_id:, rule_id:, result:, overridden:, current:}]
    #                   task.before_claim checks, for claimable_filter.
    #   built_by:       {task_id => [credential provider]}
    #   past_holders:   {task_id => [seat_id]}
    #   reviews:        {review_id => task_id}
    #   seat_providers: {seat_id => credential provider}
    class StandIn
      def initialize(rules: [], transitions: {}, actions: {}, claim_checks: [], built_by: {}, past_holders: {}, reviews: {},
                     seat_providers: {})
        @rules = rules
        @transitions = transitions
        @actions = actions
        @claim_checks = claim_checks
        @built_by = built_by
        @past_holders = past_holders
        @reviews = reviews
        @seat_providers = seat_providers
      end

      def evaluate(request)
        hook!(request.hook)
        input_hash = Gating.input_hash(hook: request.hook, inputs: request.inputs)
        enabled = rules_at(request.hook)
        plan = new_plan
        deferred = []
        if request.hook == ACTION_HOOK
          # L138: the gates first; the approval policy only once every gate
          # has cleared, and never after a failed gate.
          gates, policies = enabled.partition { |rule| rule[:kind] == "gate" }
          gates.each { |rule| plan_rule(rule, request, input_hash, plan) }
          if plan[:failures].empty? && plan[:pending]
            deferred = policies.map { |rule| rule[:id] }
          elsif plan[:failures].empty?
            policies.each { |rule| plan_rule(rule, request, input_hash, plan) }
          end
        else
          enabled.each { |rule| plan_rule(rule, request, input_hash, plan) }
        end
        Evaluation.new(outcome: plan[:pending] ? :pending : :completed,
                       frozen_rule_version_ids: enabled.map { |rule| rule[:version_id] },
                       checks: plan[:checks], jobs: plan[:jobs], failures: plan[:failures],
                       warnings: plan[:warnings], effects: plan[:effects], holds_to_open: [],
                       deferred_rule_ids: deferred)
      end

      def reenter_action(action_id:, trigger:)
        action = @actions.fetch(action_id)
        gates = action.fetch(:checks).select { |check| blocking?(rule(check[:rule_id])) && !check[:overridden] }
        return decision(:keep_pending) if gates.any? { |check| check[:result].nil? }

        errored = gates.select { |check| check[:result] == "error" }
        unless errored.empty?
          holds = errored.map { |check| PlannedHold.new(reason: "check_error", rule_id: check[:rule_id], rule_check_id: check[:id]) }
          return decision(:keep_pending, holds_to_open: holds)
        end
        failed = gates.select { |check| check[:result] == "failed" }
        unless failed.empty?
          failures = failed.map do |check|
            Failure.new(rule_id: check[:rule_id], rule_check_ref: check[:id], reason: nil, route: rule(check[:rule_id])[:route])
          end
          return decision(:refuse, failures: failures)
        end

        request = action.fetch(:request)
        input_hash = Gating.input_hash(hook: request.hook, inputs: request.inputs)
        plan = new_plan
        rules_at(ACTION_HOOK).select { |rule| rule[:kind] == "policy" }.each { |rule| plan_rule(rule, request, input_hash, plan) }
        decision(:complete, checks: plan[:checks], jobs: plan[:jobs])
      end

      def reenter(pending_transition_id:, trigger:)
        transition = @transitions.fetch(pending_transition_id)
        checks = transition.fetch(:checks)
        return decision(:cancel, checks_to_withdraw: checks.map { |check| check[:id] }) if transition[:inputs_changed]

        blocking = checks.select { |check| blocking?(rule(check[:rule_id])) && !check[:overridden] }
        return decision(:keep_pending) if blocking.any? { |check| check[:result].nil? }

        errored = blocking.select { |check| check[:result] == "error" }
        unless errored.empty?
          holds = errored.map { |check| PlannedHold.new(reason: "check_error", rule_id: check[:rule_id], rule_check_id: check[:id]) }
          return decision(:keep_pending, holds_to_open: holds)
        end
        return decision(:keep_pending) if transition[:held]

        failed = blocking.select { |check| check[:result] == "failed" }
        return decision(:complete) if failed.empty?

        failures = failed.map do |check|
          Failure.new(rule_id: check[:rule_id], rule_check_ref: check[:id], reason: nil, route: rule(check[:rule_id])[:route])
        end
        decision(:refuse, failures: failures)
      end

      def briefing_rules(task_id:, seat_id:, review_id: nil)
        @rules.select { |rule| rule[:enabled] && rule[:scope] != "not_covered" }.sort_by { |rule| rule[:id] }.map do |rule|
          BriefingPart.new(kind: :rule, id: rule[:id], version: rule[:version], may_apply: rule[:scope] == "checker_decides")
        end
      end

      def built_by_providers(task_id:)
        @built_by.fetch(task_id, []).map { |provider| provider_group(provider) }.uniq
      end

      def provider_allowed?(task_id:, provider:)
        group = provider_group(provider)
        return true if rules_at("review.assign").empty?

        !built_by_providers(task_id: task_id).include?(group)
      end

      def claimable_filter(seat_id:, kind:)
        case kind
        when :task
          failed = @claim_checks.select do |check|
            check[:seat_id] == seat_id && check[:result] == "failed" && !check[:overridden] && check[:current]
          end
          ClaimFilter.new(excluded_task_ids: failed.map { |check| check[:task_id] }.uniq, excluded_review_ids: [])
        when :review
          excluded = @reviews.select { |_, task_id| !may_review?(seat_id, task_id) }.keys
          ClaimFilter.new(excluded_task_ids: [], excluded_review_ids: excluded)
        else
          raise ArgumentError, "kind must be :task or :review, got #{kind.inspect}"
        end
      end

      private

      ACTION_HOOK = "action.requested".freeze

      def new_plan = { checks: [], jobs: [], failures: [], warnings: [], effects: [], pending: false }

      def hook!(hook)
        raise ArgumentError, "unknown hook #{hook.inspect}" unless Contract.registry.fetch("hooks").include?(hook)
      end

      def rules_at(hook)
        @rules.select { |rule| rule[:hook] == hook && rule[:enabled] }
      end

      def rule(id)
        @rules.find { |candidate| candidate[:id] == id } || raise(KeyError, "no rule #{id}")
      end

      # A gate that blocks the transition when it fails or cannot run.
      def blocking?(rule)
        rule[:kind] == "gate" && rule[:on_fail] == "block"
      end

      def plan_rule(rule, request, input_hash, plan)
        ref = plan[:checks].size
        if rule[:scope] == "not_covered"
          plan[:checks] << check(rule, request, input_hash, result: "not_applicable") unless quiet_policy?(rule)
        elsif rule[:checker] == "model"
          plan_model(rule, request, input_hash, ref, plan)
        elsif rule[:kind] == "policy"
          plan_app_policy(rule, request, input_hash, plan)
        else
          plan_app_gate(rule, request, input_hash, ref, plan)
        end
      end

      def plan_model(rule, request, input_hash, ref, plan)
        plan[:checks] << check(rule, request, input_hash, result: nil)
        kind = rule[:kind] == "policy" ? "approval" : "rule_check"
        plan[:jobs] << PlannedJob.new(kind: kind, rule_check_ref: ref, seat_role: "orchestrator")
        plan[:pending] ||= blocking?(rule)
      end

      def plan_app_policy(rule, request, input_hash, plan)
        return if rule[:effect].nil? && quiet_policy?(rule)

        plan[:checks] << check(rule, request, input_hash, result: "applied", effect: rule[:effect])
        plan[:effects] << Effect.new(rule_id: rule[:id], hook: rule[:hook], effect: rule[:effect]) if rule[:effect]
      end

      def plan_app_gate(rule, request, input_hash, ref, plan)
        result = rule.fetch(:app_result, "passed")
        plan[:checks] << check(rule, request, input_hash, result: result)
        return unless result == "failed"

        failure = Failure.new(rule_id: rule[:id], rule_check_ref: ref, reason: nil, route: rule[:route])
        (rule[:on_fail] == "block" ? plan[:failures] : plan[:warnings]) << failure
      end

      # A policy whose hook writes a row only when it changes the outcome
      # (PRD, How a transition is gated, step 7).
      def quiet_policy?(rule)
        return false unless rule[:kind] == "policy"

        hook = Contract.hooks.fetch("hooks").find { |entry| entry["hook"] == rule[:hook] }
        hook.fetch("policy_row") == "when_it_changes_the_outcome"
      end

      def check(rule, request, input_hash, result:, effect: nil)
        PlannedCheck.new(rule_id: rule[:id], rule_version_id: rule[:version_id], hook: request.hook, round: request.round,
                         subject_kind: request.subject_kind, subject_id: request.subject_id, input_hash: input_hash,
                         checker: rule[:checker], result: result, effect: effect, reason: nil)
      end

      def decision(action, failures: [], holds_to_open: [], checks_to_withdraw: [], checks: [], jobs: [])
        Decision.new(action: action, failures: failures, effects: [], holds_to_open: holds_to_open, holds_to_close: [],
                     checks_to_withdraw: checks_to_withdraw, checks: checks, jobs: jobs)
      end

      def may_review?(seat_id, task_id)
        return false if @past_holders.fetch(task_id, []).include?(seat_id)

        provider = @seat_providers[seat_id]
        provider.nil? || provider_allowed?(task_id: task_id, provider: provider)
      end

      def provider_group(provider)
        entry = Contract.registry.fetch("credential_providers").find { |candidate| candidate["provider"] == provider }
        raise ArgumentError, "unknown provider #{provider.inspect}" unless entry

        entry.fetch("provider_group")
      end
    end
  end
end
