module Leverage
  # The in-process interface between the transition function and rule gating
  # (PRD, Contract milestone; plan §1.2). The transition function calls it
  # inside the command's transaction; gating reads rules, checks and the task's
  # inputs and returns what it decided. It never writes a row or an event: the
  # transition function writes every row and event the result plans (PRD,
  # Event log, principle 1).
  #
  # Every call goes to the implementation set with implementation=. Track B
  # (Rules engine) supplies the real one; StandIn decides from an in-memory
  # world with no database. Both pass test/support/gating_conformance.rb.
  module Gating
    # Raised by a call when no implementation is set.
    class NotConfigured < StandardError; end

    class << self
      # Gates a transition at a hook. Called inside the command's transaction,
      # after due timers are applied and the command is validated against the
      # state machine (PRD, How a transition is gated, steps 1-5).
      #
      # request - a Request.
      #
      # Returns an Evaluation: :pending when a blocking model check is planned,
      # :completed otherwise, with the rule check rows, jobs, failures, warnings,
      # policy effects and holds the transition function must write. At
      # action.requested the gates are planned first; the approval policy is
      # planned too when every gate has a result and none failed, is left out
      # when a gate failed (the action is stopped), and is returned in
      # deferred_rule_ids while a gate is still running (see reenter_action).
      def evaluate(request)
        implementation!.evaluate(request)
      end

      # Gates a pending transition again when something it waits on changes: a
      # check finishes, times out, is overridden, re-run or withdrawn, a rule is
      # switched off or removed, or the last hold lifts (step 6).
      #
      # pending_transition_id - the pending_transitions id.
      # trigger               - a Trigger.
      #
      # Returns a Decision: :complete, :refuse, :cancel or :keep_pending.
      def reenter(pending_transition_id:, trigger:)
        implementation!.reenter(pending_transition_id: pending_transition_id, trigger: trigger)
      end

      # Gates one outward action again when one of its gate checks finishes,
      # times out, is overridden, re-run or withdrawn, or its rule is switched
      # off. Checks at action.requested are keyed per action and are not
      # pending transitions (PRD L384), and the approval policy runs only once
      # every gate has passed, did not apply, was withdrawn or was overridden
      # (L138), so evaluate returns the approval policy in deferred_rule_ids
      # while a gate is still running, and this call plans it.
      #
      # action_id - the actions id.
      # trigger   - a Trigger.
      #
      # Returns a Decision: :complete with the approval policy's check rows and
      # jobs in checks and jobs (none when the policy is off: the transition
      # function then holds the action with owner_approval), :refuse with the
      # gate failures that stop the action, or :keep_pending while a gate runs
      # or has ended in error (with its check_error hold).
      def reenter_action(action_id:, trigger:)
        implementation!.reenter_action(action_id: action_id, trigger: trigger)
      end

      # The input hash of a rule check: SHA-256, in lower-case hex, of
      # CanonicalJson.dump(inputs). inputs must have exactly the keys the hook
      # hashes, its hashed_inputs in hooks.json. Raises ArgumentError for an
      # unknown hook, other keys, or a value with no canonical form.
      def input_hash(hook:, inputs:)
        expected = hashed_inputs(hook)
        unless inputs.is_a?(Hash) && inputs.keys.sort == expected.sort
          raise ArgumentError, "#{hook} hashes #{expected.inspect}, got #{inputs.is_a?(Hash) ? inputs.keys.inspect : inputs.class}"
        end

        CanonicalJson.digest(inputs)
      end

      # The rules a seat's briefing on a task holds: every enabled rule whose
      # fixed scope covers the task, and every "let the checker decide" rule
      # marked may_apply (PRD, The briefing). A reviewer's briefing holds the
      # same rules (plan RC-31).
      #
      # Returns an Array of BriefingPart of kind :rule, with each version.
      def briefing_rules(task_id:, seat_id:, review_id: nil)
        implementation!.briefing_rules(task_id: task_id, seat_id: seat_id, review_id: review_id)
      end

      # The provider groups that have built the task, read from the log (PRD,
      # Shipped rules: task.claimed, credential.switched while a builder held
      # it, and seats that held it with no credential).
      def built_by_providers(task_id:)
        implementation!.built_by_providers(task_id: task_id)
      end

      # Whether the provider rule lets a reviewer or a review's credential of
      # this provider (a credential_providers value) work on the task's review.
      # Always true while the rule is off.
      def provider_allowed?(task_id:, provider:)
        implementation!.provider_allowed?(task_id: task_id, provider: provider)
      end

      # What claim-next must skip for this seat, read under the workspace lock
      # so the claim stays atomic (plan RC-19, RC-50). kind is :task or :review.
      # Returns a ClaimFilter.
      def claimable_filter(seat_id:, kind:)
        implementation!.claimable_filter(seat_id: seat_id, kind: kind)
      end

      # Sets the implementation every call goes to; nil unsets it.
      def implementation=(impl)
        @implementation = impl
      end

      def implementation
        @implementation
      end

      private

      def implementation!
        @implementation || raise(NotConfigured, "Leverage::Gating.implementation is not set")
      end

      def hashed_inputs(hook)
        entry = Contract.hooks.fetch("hooks").find { |candidate| candidate["hook"] == hook }
        raise ArgumentError, "unknown hook #{hook.inspect}" unless entry

        entry.fetch("hashed_inputs")
      end
    end
  end
end
