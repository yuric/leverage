module Leverage
  module Transitions
    module Entries
      # The orchestrator_offline timer (PRD L401, L402; timers.json;
      # milestone 4 plan RD-15 to RD-20): a workspace timer the sweep fires
      # on every run; it opens and resolves the Orchestrator offline item.
      #
      # First version (milestone 4 plan §4, the hand-over table): does nothing.
      # WP7 writes it.
      class OrchestratorOffline < Entry
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
