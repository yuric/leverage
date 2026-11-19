module Leverage
  module Gating
    # A gate that failed: the rule, the check (an index into Evaluation#checks
    # for a check planned by evaluate, or a rule_checks id), the reason the
    # checker gave (content, stored on the row, never in a payload), and the
    # route: who receives it (registry lists.routes).
    Failure = Data.define(:rule_id, :rule_check_ref, :reason, :route) do
      def initialize(route:, **fields)
        raise ArgumentError, "unknown route #{route.inspect}" unless Contract.list("routes").include?(route)

        super(route: route, **fields)
      end
    end
  end
end
