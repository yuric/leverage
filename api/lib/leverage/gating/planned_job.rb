module Leverage
  module Gating
    # A jobs row gating plans. kind is a registry job kind; rule_check_ref is
    # the index, in Evaluation#checks, of the check whose attempt it runs;
    # seat_role is the role that claims it.
    PlannedJob = Data.define(:kind, :rule_check_ref, :seat_role) do
      def initialize(kind:, seat_role:, **fields)
        unless Contract.registry.fetch("job_kinds").any? { |entry| entry["kind"] == kind }
          raise ArgumentError, "unknown job kind #{kind.inspect}"
        end
        raise ArgumentError, "unknown seat role #{seat_role.inspect}" unless Contract.list("seat_roles").include?(seat_role)

        super(kind: kind, seat_role: seat_role, **fields)
      end
    end
  end
end
