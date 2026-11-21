module Leverage
  module Transitions
    # Why a command was refused (IF-4): code is a registry refusal; rule_id
    # and reason are set only for blocked_by_rule, which needs rules
    # (milestone 4).
    Refusal = Data.define(:code, :rule_id, :reason, :task_id) do
      def initialize(code:, rule_id: nil, reason: nil, task_id: nil)
        super(code: code.to_s, rule_id: rule_id, reason: reason, task_id: task_id)
      end

      # The rendered form, the contract's Refusal. The task ID is private
      # to the receipt and allows deletion to clear only this task's text.
      def to_h = { "code" => code, "rule_id" => rule_id, "reason" => reason }
    end
  end
end
