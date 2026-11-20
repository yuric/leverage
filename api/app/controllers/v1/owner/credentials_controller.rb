module V1
  module Owner
    # The owner's credential calls: the Credentials list, Add credential,
    # Verify and Sign in again (milestone 2 plan IN-23, IN-24; milestone 3
    # plan HE-36). Each command completes at once with the id of the helper
    # request the app then follows.
    class CredentialsController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      def index
        render json: Leverage::Reads::Credentials.call(current_caller.workspace_id)
      end

      def create
        run_command("add_credential", params: checked_body("add_credential"))
      end

      def verify
        run_command("verify_credential", params: checked_body("verify_credential").merge("id" => uuid_param!(:id)))
      end

      # Sign in again (milestone 3 plan HE-36): the entry queues one
      # open_sign_in helper request for an added login, or answers the
      # unfinished one, and the app follows it with get_helper_request.
      def sign_in
        run_command("sign_in_again", params: checked_body("sign_in_again").merge("id" => uuid_param!(:id)))
      end
    end
  end
end
