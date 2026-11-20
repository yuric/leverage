module Leverage
  module Transitions
    module Entries
      # enable_rule (PRD L379; milestone 4 plan RD-3): the owner turns a
      # rule on; a request already made is not touched.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class EnableRule < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
