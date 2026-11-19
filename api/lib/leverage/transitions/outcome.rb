module Leverage
  module Transitions
    # What a command came to (IF-4). outcome is :completed, :refused or
    # :pending (never :pending in milestone 2). result is the token-free
    # result, a Hash with string keys or nil, and is what commands.result
    # stores. once holds the values shown in this response only and never
    # stored: a token (IN-11). A repeat of the key answers the stored
    # outcome, whose once is nil.
    Outcome = Data.define(:outcome, :result, :refusal, :once) do
      def self.completed(result = nil, once: nil)
        new(outcome: :completed, result: result, refusal: nil, once: once)
      end

      def self.refused(refusal)
        new(outcome: :refused, result: nil, refusal: refusal, once: nil)
      end

      def initialize(outcome:, result: nil, refusal: nil, once: nil)
        super(outcome: outcome.to_sym, result: result&.deep_stringify_keys, refusal: refusal,
              once: once&.deep_stringify_keys)
      end

      def completed? = outcome == :completed
      def refused? = outcome == :refused
    end
  end
end
