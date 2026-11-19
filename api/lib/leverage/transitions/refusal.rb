module Leverage
  module Transitions
    # Why a command was refused (IF-4): code is a registry refusal; rule_id
    # and reason are set only for blocked_by_rule, which needs rules
    # (milestone 4).
    Refusal = Data.define(:code, :rule_id, :reason) do
      def initialize(code:, rule_id: nil, reason: nil)
        super(code: code.to_s, rule_id: rule_id, reason: reason)
      end

      # The stored and rendered form, the contract's Refusal.
      def to_h = { "code" => code, "rule_id" => rule_id, "reason" => reason }
    end
  end
end
