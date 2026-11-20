module Leverage
  module Rules
    # Red stub (WP3): a claim filters nothing.
    module ClaimFilter
      module_function

      def call(seat_id:, kind:) = Gating::ClaimFilter.new(excluded_task_ids: [], excluded_review_ids: [])
    end
  end
end
