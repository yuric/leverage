module Leverage
  module Transitions
    module Entries
      # promote (milestone 3 plan HE-24): the owner moves an
      # idea from the Imaginarium to the Backlog.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class Promote < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
