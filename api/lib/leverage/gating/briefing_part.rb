module Leverage
  module Gating
    # One part of a briefing and its version, which the briefing hash covers
    # (PRD, The briefing). Gating returns the :rule parts; may_apply marks a
    # "let the checker decide" rule. The brief, role file and contract parts
    # use the same value.
    BriefingPart = Data.define(:kind, :id, :version, :may_apply) do
      const_set(:KINDS, %i[rule brief role_file contract].freeze)

      def initialize(kind:, id:, version:, may_apply:)
        raise ArgumentError, "kind must be one of #{self.class::KINDS.inspect}" unless self.class::KINDS.include?(kind)

        super
      end
    end
  end
end
