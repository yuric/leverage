module Leverage
  module Transitions
    module Entries
      # sign_in_again (PRD L198, L611, L697; milestone 3 plan HE-36): the
      # owner asks the helper to open the provider's own sign-in for an
      # added login. It queues one open_sign_in request, with the login's
      # provider and kind as params and never its name, or answers the
      # unfinished one for that account, and writes no event. The helper
      # waits for the sign-in, runs the verify checks and reports through
      # report_request_result, which writes the outcome.
      #
      # A credential of another workspace, or none, is 404; anything but an
      # added login (an add still running, an API token) is 422 invalid.
      #
      # Params: "id" (the credential).
      class SignInAgain < Entry
        def load(ctx)
          @credential = Credential.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id)
          raise NotFound, "No such credential" unless @credential
          raise Invalid, "Sign in again is for an added login" unless @credential.kind == "login" && @credential.last_verified_at
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          request = HelperRequest.where(workspace_id: ctx.workspace.id, credential_id: @credential.id, kind: "open_sign_in",
            state: SeatRuns::UNFINISHED).order(:requested_at, :id).first
          request ||= SeatRuns.queue(ctx, "open_sign_in", credential_id: @credential.id,
            params: { "provider" => @credential.provider, "credential_kind" => @credential.kind })
          @result = { "helper_request_id" => request.id }
        end
      end
    end
  end
end
