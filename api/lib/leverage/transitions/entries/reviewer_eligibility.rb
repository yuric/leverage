module Leverage
  module Transitions
    module Entries
      # The reviewer_eligibility timer (PRD L448; timers.json; milestone 4
      # plan RD-51, SM-42): a workspace timer the sweep fires on every run;
      # it resolves No reviewer is eligible when a reviewer may take the
      # review again.
      #
      # First version (milestone 4 plan §4, the hand-over table): does nothing.
      # WP9 writes it.
      class ReviewerEligibility < Entry
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
