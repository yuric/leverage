module Leverage
  module Gating
    # A rule_checks row gating plans, with its first attempt. result is a
    # registry check result, or nil for a model check queued as a job; effect
    # is the policy effect of an applied row, or nil. checker is "app" or
    # "model"; an app check's single attempt is queued, started and finished at
    # once (plan DB-30).
    PlannedCheck = Data.define(:rule_id, :rule_version_id, :hook, :round, :subject_kind, :subject_id, :input_hash,
                               :checker, :result, :effect, :reason) do
      def initialize(result:, **fields)
        unless result.nil? || Contract.registry.fetch("check_results").include?(result)
          raise ArgumentError, "unknown check result #{result.inspect}"
        end

        super(result: result, **fields)
      end
    end
  end
end
