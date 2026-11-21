module Leverage
  module Transitions
    module Entries
      # Remove checks live references before deleting the credential (CR-32).
      # Its absence may change which candidates a held task can wait for.
      class RemoveCredential < Entry
        def load(ctx)
          @credential = Credential.added.find_by(workspace_id: ctx.workspace.id, id: ctx.request.params["id"])
          raise NotFound, "No such credential" unless @credential
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: "credential_in_use") if CredentialUse.in_use?(@credential)
          causes.compact
        end

        def perform(ctx)
          CredentialUse.release(ctx, @credential)
          removed = ctx.emit("credential.removed", subject: @credential, payload: {})
          @credential.destroy!
          Handoff.reevaluate(ctx, cause: removed)
        end
      end
    end
  end
end
