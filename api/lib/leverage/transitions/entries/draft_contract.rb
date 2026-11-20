module Leverage
  module Transitions
    module Entries
      # draft_contract (PRD L110, L802; milestone 4 plan RD-37): the owner
      # asks a planner to write a Backlog task's contract.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class DraftContract < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
