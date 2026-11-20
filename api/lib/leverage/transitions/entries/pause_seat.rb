module Leverage
  module Transitions
    module Entries
      # pause_seat (milestone 3 plan HE-26): the owner pauses an
      # agent; a task it holds is held with seat_paused.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class PauseSeat < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
