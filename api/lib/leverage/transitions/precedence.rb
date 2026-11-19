module Leverage
  module Transitions
    # Which refusal a command answers when several apply (PRD L548; IF-9,
    # I-13): the lowest registry precedence first, and not_eligible, which
    # has none and applies to claims only, after every ranked code.
    module Precedence
      module_function

      # refusals - Refusals or codes.
      #
      # Returns the first Refusal, or nil for none. Raises ArgumentError for
      # a code the registry does not have.
      def first(refusals)
        refusals.map { |refusal| refusal.is_a?(Refusal) ? refusal : Refusal.new(code: refusal) }
          .min_by { |refusal| rank(refusal.code) }
      end

      def rank(code)
        entry = Contract.registry.fetch("refusals").find { |candidate| candidate.fetch("code") == code }
        raise ArgumentError, "not a registry refusal: #{code.inspect}" unless entry

        entry.fetch("precedence") || Float::INFINITY
      end
    end
  end
end
