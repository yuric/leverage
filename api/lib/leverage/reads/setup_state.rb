module Leverage
  module Reads
    # get_setup_state (milestone 2 plan IN-2): whether the one owner of this
    # installation exists, so the app shows Create your sign-in or Sign in.
    # It says nothing else, and needs no sign-in. One SELECT.
    module SetupState
      module_function

      def call
        { owner_exists: User.exists? }
      end
    end
  end
end
