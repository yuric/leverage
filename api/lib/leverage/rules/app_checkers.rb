module Leverage
  module Rules
    # Red stub (WP3): the app checkers and what acts.
    module AppCheckers
      Result = Data.define(:result, :reason, :effect)
      BUILT = {}.freeze

      module_function

      def built?(_function) = false

      def runs?(_version) = false

      def acts?(_version) = false

      def check(_version, request:, task:) = Result.new(result: nil, reason: nil, effect: nil)
    end
  end
end
