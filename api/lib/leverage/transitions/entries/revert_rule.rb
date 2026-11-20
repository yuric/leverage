module Leverage
  module Transitions
    module Entries
      # revert_rule (PRD L342; milestone 4 plan RD-5, RD-7): the owner
      # reverts a shipped rule to its default as a new version.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class RevertRule < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
