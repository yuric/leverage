module Leverage
  module Gating
    # What a policy rule chose at its hook: one of the registry's
    # policy_effects for that hook.
    Effect = Data.define(:rule_id, :hook, :effect) do
      def initialize(hook:, effect:, rule_id:)
        allowed = Contract.registry.fetch("policy_effects").fetch(hook, [])
        raise ArgumentError, "#{hook} has no policy effect #{effect.inspect}" unless allowed.include?(effect)

        super
      end
    end
  end
end
