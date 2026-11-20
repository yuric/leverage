module Leverage
  module Transitions
    module Entries
      # disable_rule (PRD L379, L973; milestone 4 plan RD-45, S-5): the
      # owner turns a rule off; its checks in flight are withdrawn and each
      # pending transition is gated again.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP8 writes it.
      class DisableRule < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
