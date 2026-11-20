module Leverage
  module Transitions
    module Entries
      # install_shipped_rules (PRD L434 with Q-12; milestone 4 plan RD-2,
      # S-1): the app writes the seven shipped rules of a workspace that has
      # none, through Timers.apply_workspace.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class InstallShippedRules < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
