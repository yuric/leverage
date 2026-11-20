module Leverage
  module Transitions
    # Asks gating at a state-table row's hook and applies what it decides
    # (PRD, How a transition is gated; milestone 2 plan EN-5). This is the
    # one piece of code milestone 4 extends: in milestone 2 the gating is
    # Gating::NoRules, which always completes with nothing planned, and any
    # other answer is refused here rather than ignored.
    module Gate
      # An Evaluation milestone 2 cannot apply: pending, or with checks,
      # jobs, failures, warnings, effects or holds to write.
      class Unsupported < StandardError; end

      PLANNED = %i[frozen_rule_version_ids checks jobs failures warnings effects holds_to_open deferred_rule_ids].freeze

      module_function

      # Returns the Evaluation, or nil when the row has no hook.
      def call(ctx, entry)
        hook = entry.hook
        return nil unless hook

        kind, id = ctx.actor
        fields = entry.gate_request_fields(ctx)
        request = Gating::Request.new(workspace_id: ctx.workspace.id, hook: hook, requester_kind: kind,
          requester_id: ctx.request.caller_id || id, command_key: ctx.request.key, **fields)
        evaluation = Gating.evaluate(request)
        apply(evaluation, hook)
        evaluation
      end

      def apply(evaluation, hook)
        raise Unsupported, "#{hook}: a pending transition needs rules (milestone 4)" if evaluation.outcome == :pending

        planned = PLANNED.reject { |field| evaluation.public_send(field).empty? }
        raise Unsupported, "#{hook}: #{planned.join(", ")} need rules (milestone 4)" unless planned.empty?
      end
    end
  end
end
