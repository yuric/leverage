module V1
  module Owner
    # The owner's credential calls: the Credentials list, Add credential and
    # Verify (milestone 2 plan IN-23, IN-24). Add and Verify complete at once
    # with the id of the helper request the app then follows.
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
    end
  end
end
