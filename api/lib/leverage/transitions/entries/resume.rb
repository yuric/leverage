module Leverage
  module Transitions
    module Entries
      # resume (milestone 3 plan HE-24): the owner continues a task
      # it paused, closing its owner_hold.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class Resume < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
