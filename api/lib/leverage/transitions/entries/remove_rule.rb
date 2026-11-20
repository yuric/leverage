module Leverage
  module Transitions
    module Entries
      # remove_rule (PRD L342; milestone 4 plan RD-5, RD-45): the owner
      # removes a custom rule; its checks in flight are withdrawn.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class RemoveRule < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
