module Leverage
  module Transitions
    module Entries
      # rerun_check (PRD L423; milestone 4 plan RD-42, RD-43): the owner
      # runs an errored check again; on an errored claim check it closes the
      # hold and queues nothing.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class RerunCheck < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
