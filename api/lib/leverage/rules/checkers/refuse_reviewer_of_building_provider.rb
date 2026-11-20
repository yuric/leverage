module Leverage
  module Rules
    module Checkers
      # Red stub (WP3).
      module RefuseReviewerOfBuildingProvider
        module_function

        def call(version:, request:, task:) = AppCheckers::Result.new(result: nil, reason: nil, effect: nil)
      end
    end
  end
end
