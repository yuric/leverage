module Leverage
  module Transitions
    module Entries
      # The seat_run_placement timer (milestone 3 plan HD-4; timers.json): a
      # workspace timer fired by every sweep, which moves an idle seat's run
      # to its first available candidate and starts again a seat whose run
      # ended for a limit or a sign-out. It writes no event.
      #
      # First version (milestone 3 plan §4, the hand-over table): does nothing.
      # WP5 writes it.
      class SeatRunPlacement < Entry
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
