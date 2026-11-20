module Leverage
  module Transitions
    module Entries
      # The check_run_timeout timer (PRD L399; timers.json): a rule check's
      # attempt not finished within its run timeout is queued once more; a
      # second miss is an error.
      #
      # First version (milestone 4 plan §4, the hand-over table): does nothing.
      # WP7 writes it.
      class CheckRunTimeout < Entry
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
