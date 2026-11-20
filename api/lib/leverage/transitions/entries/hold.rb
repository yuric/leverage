module Leverage
  module Transitions
    module Entries
      # hold (milestone 3 plan HE-24): the owner pauses a task with
      # an owner_hold. Inside Entries this class is Hold: the model is
      # ::Hold.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class Hold < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
