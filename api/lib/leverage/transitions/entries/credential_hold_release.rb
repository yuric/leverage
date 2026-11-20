module Leverage
  module Transitions
    module Entries
      # The credential_hold_release timer (PRD L696-L699; timers.json;
      # milestone 3 plan §2.1 rules 7 and 8, HE-23): a task timer, due when
      # one of the seat's candidates is available or at the earliest reset.
      #
      # First version (milestone 3 plan §4, the hand-over table): does nothing.
      # WP4 writes it.
      class CredentialHoldRelease < Entry
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
