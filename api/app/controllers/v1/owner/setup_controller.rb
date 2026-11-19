module V1
  module Owner
    # The first sign-in of an installation (milestone 2 plan IN-2, IN-9):
    # get_setup_state says whether the owner exists, and create_owner makes
    # the workspace, the owner and a session. Both are public: no sign-in
    # exists yet, and the API listens on loopback only.
    class SetupController < ApplicationController
      include RunsCommands

      # GET /v1/owner/setup
      def show
        render json: Leverage::Reads::SetupState.call
      end

      # POST /v1/owner/setup. The commands row is the owner's; a repeat of
      # the key is recognised only for the owner the email address and the
      # password sign in, so a repeat never tells anyone else that the key
      # was used. Anything else, once an owner exists, is 404 (IN-2). The
      # request hash leaves the password out (IN-9).
      def create
        body = Leverage::Http::RequestSchema.body!("create_owner", request.raw_post)
        owner = User.authenticate_by(email_address: body.fetch("email_address"), password: body.fetch("password"))
        run_command("create_owner", params: body, hash_without: [ "password" ], caller_kind: "owner",
          caller_id: owner&.id, workspace_id: nil)
      end
    end
  end
end
