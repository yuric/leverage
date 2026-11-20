module Leverage
  module Transitions
    module Entries
      # resume_seat (milestone 3 plan HE-26): the owner resumes a paused
      # agent.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class ResumeSeat < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
