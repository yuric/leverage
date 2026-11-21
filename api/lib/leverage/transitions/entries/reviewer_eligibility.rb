module Leverage
  module Transitions
    module Entries
      # The reviewer_eligibility timer (PRD L451; timers.json; milestone 4
      # plan RD-51, SM-42): a workspace timer the sweep fires on every run
      # (Timers.apply_workspace), for what changes who may review with no
      # command, such as a credential reset: it opens or resolves No
      # reviewer is eligible for every waiting review, as the app, with no
      # key, effective at the time it is given.
      #
      # The work is Leverage::ReviewerEligibility's, which the pipeline runs
      # after the perform of every command of its REEVALUATED_BY, this
      # timer among them; the timer itself changes nothing else.
      class ReviewerEligibility < Entry
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
