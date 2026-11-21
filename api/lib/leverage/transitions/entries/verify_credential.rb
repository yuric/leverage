module Leverage
  module Transitions
    module Entries
      # Verify queues a new request for one added credential. Verify all
      # queues one per added credential and keeps unfinished verifies (CR-11).
      # Neither writes an event. The helper's result records the outcome.
      #
      # Params: "id" for one credential, absent for Verify all.
      class VerifyCredential < Entry
        def load(ctx)
          @added = Credential.added.where(workspace_id: ctx.workspace.id)
          return unless ctx.request.params.key?("id")

          @credential = @added.find_by(id: ctx.request.params["id"])
          raise NotFound, "No such credential" unless @credential
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          @result = if @credential
            { "helper_request_id" => queue_verify(ctx, @credential).id }
          else
            { "helper_request_ids" => verify_all(ctx) }
          end
        end

        private

        def verify_all(ctx)
          credentials = @added.order(:position).to_a
          unfinished = HelperRequest.where(workspace_id: ctx.workspace.id, kind: "verify", state: SeatRuns::UNFINISHED,
            credential_id: credentials.map(&:id)).order(:requested_at, :id).group_by(&:credential_id)
          credentials.map do |credential|
            request = unfinished[credential.id]&.first || queue_verify(ctx, credential)
            request.id
          end
        end

        def queue_verify(ctx, credential)
          SeatRuns.queue(ctx, "verify", credential_id: credential.id,
            params: { "provider" => credential.provider, "credential_kind" => credential.kind })
        end
      end
    end
  end
end
