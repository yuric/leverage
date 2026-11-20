module Leverage
  module Transitions
    module Entries
      # add_rule (PRD L342, L423; milestone 4 plan RD-4, RD-21 to
      # RD-24): the owner adds a custom rule at one of four moments.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class AddRule < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
