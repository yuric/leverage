module Leverage
  module Transitions
    module Entries
      # Credentials keep their names on their own rows (PRD, Credentials).
      class RenameCredential < Entry
        def load(ctx)
          @credential = Credential.added.find_by(workspace_id: ctx.workspace.id, id: ctx.request.params["id"])
          raise NotFound, "No such credential" unless @credential

          @name = ctx.request.params["name"]
          raise Invalid, "A credential needs a name" unless @name.is_a?(String) && !@name.empty?
        end

        def refusals(ctx)
          causes = [ state_refusal(nil) ]
          credentials = Credential.where(workspace_id: ctx.workspace.id, kind: @credential.kind,
            provider: @credential.provider, name: @name)
          causes << Refusal.new(code: "duplicate_name") if credentials.where.not(id: @credential.id).exists?
          causes.compact
        end

        def perform(ctx)
          @credential.update!(name: @name, updated_at: ctx.at)
          ctx.emit("credential.renamed", subject: @credential, payload: {})
        end
      end
    end
  end
end
