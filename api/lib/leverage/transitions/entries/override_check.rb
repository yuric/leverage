module Leverage
  module Transitions
    module Entries
      # override_check (PRD L423, L910; milestone 4 plan RD-45, RD-47,
      # RD-48): the owner lets one failed, errored or held check through.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class OverrideCheck < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
