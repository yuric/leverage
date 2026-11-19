module Leverage
  module Gating
    # What claim-next skips for one seat: tasks it may not claim because it
    # failed their task.before_claim gate on the current inputs, and reviews
    # it may not take.
    ClaimFilter = Data.define(:excluded_task_ids, :excluded_review_ids) do
      def initialize(excluded_task_ids:, excluded_review_ids:)
        super(excluded_task_ids: excluded_task_ids.dup.freeze, excluded_review_ids: excluded_review_ids.dup.freeze)
      end
    end
  end
end
