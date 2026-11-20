module Leverage
  module Transitions
    module Entries
      # change_seat (milestone 3 plan HE-27): the owner changes an
      # agent's name, model, effort, strength rank, login, role or whether
      # it is on.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class ChangeSeat < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
