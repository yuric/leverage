module Leverage
  module Transitions
    module Entries
      # save_rule (PRD L342, L911; milestone 4 plan RD-6): the owner saves
      # a rule as a new version; earlier checks keep theirs.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class SaveRule < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
