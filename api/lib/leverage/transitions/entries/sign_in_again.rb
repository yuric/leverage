module Leverage
  module Transitions
    module Entries
      # sign_in_again (PRD L699; milestone 3 plan HE-36): the owner asks the
      # helper to open the provider's own sign-in for an added login; it
      # queues one open_sign_in request and writes no event.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP5 writes it.
      class SignInAgain < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
