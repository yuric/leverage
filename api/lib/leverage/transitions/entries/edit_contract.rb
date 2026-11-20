module Leverage
  module Transitions
    module Entries
      # edit_contract (milestone 3 plan HE-25): the owner
      # edits a task's contract.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class EditContract < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
