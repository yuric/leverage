module V1
  module Owner
    # The owner's credential list and commands. Add, Verify, Sign in again,
    # Refresh and Verify all return the ids of helper requests the app can follow.
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

      def rename
        run_command("rename_credential", params: checked_body("rename_credential").merge("id" => uuid_param!(:id)))
      end

      def remove
        run_command("remove_credential", params: checked_body("remove_credential").merge("id" => uuid_param!(:id)))
      end

      def reorder
        run_command("reorder_credentials", params: checked_body("reorder_credentials"))
      end

      def refresh
        run_command("refresh_usage", params: checked_body("refresh_usage"))
      end

      def verify_all
        run_command("verify_credential", params: checked_body("verify_all_credentials"))
      end
    end
  end
end
