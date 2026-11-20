module V1
  module Owner
    # The owner's session (milestone 2 plan IN-5, IN-9, IN-13): sign_in_owner
    # opens one and returns its token once; sign_out_owner ends the one the
    # bearer token names.
    class SessionsController < ApplicationController
      include AuthenticatesOwner
      include RunsCommands

      skip_before_action :authenticate_owner!, only: :create

      # POST /v1/owner/session. The password is checked here, before the
      # pipeline: a wrong password or an unknown address is 401 and stores
      # no commands row, also for a key used before. authenticate_by spends
      # the same time on an unknown address. The password is left out of the
      # request hash and of the command's params (IN-9).
      def create
        body = Leverage::Http::RequestSchema.body!("sign_in_owner", request.raw_post)
        user = User.authenticate_by(email_address: body.fetch("email_address"), password: body.fetch("password"))
        raise Unauthenticated, "The email address or the password is not right" unless user

        run_command("sign_in", params: body.except("password"), hash_without: [ "password" ], caller_kind: "owner",
          caller_id: user.id, workspace_id: user.workspace_id)
      end

      # POST /v1/owner/session/sign-out. A session another sign-out ended
      # first is 401, like the repeat of this call's key.
      def sign_out
        Leverage::Http::RequestSchema.body!("sign_out_owner", request.raw_post)
        run_command("sign_out", params: { "session_id" => current_session.id })
      rescue Leverage::Transitions::Entries::SignOut::SessionEnded
        raise Unauthenticated
      end
    end
  end
end
