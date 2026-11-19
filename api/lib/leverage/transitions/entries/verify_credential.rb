module Leverage
  module Transitions
    module Entries
      # verify_credential (PRD L613; milestone 2 plan IN-23, IN-25): queues
      # a verify request for an added credential, with its provider and kind
      # as params, and writes no event; report_request_result writes the
      # outcome. A credential whose add still runs (it has never passed its
      # checks, IN-24) is not an added credential: 404, like one that does
      # not exist.
      #
      # Params: "id" (the credential).
      class VerifyCredential < Entry
        def load(ctx)
          @credential = Credential.where.not(last_verified_at: nil)
            .find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id)
          raise NotFound, "No such credential" unless @credential
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          request = SeatRuns.queue(ctx, "verify", credential_id: @credential.id,
            params: { "provider" => @credential.provider, "credential_kind" => @credential.kind })
          @result = { "helper_request_id" => request.id }
        end
      end
    end
  end
end
