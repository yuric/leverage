module Leverage
  module Transitions
    module Entries
      # claim_job (PRD L540, L545; milestone 4 plan RD-34 to RD-36,
      # RD-40): an orchestrator or a planner claims the oldest job it may
      # take, or gets the one it holds again.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class ClaimJob < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
