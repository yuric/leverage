module Leverage
  module Transitions
    module Entries
      # Credentials keep their names on their own rows (PRD, Credentials).
      class RenameCredential < Entry
        def load(ctx)
          @credential = Credential.added.find_by(workspace_id: ctx.workspace.id, id: ctx.request.params["id"])
          raise NotFound, "No such credential" unless @credential

          @name = Credential.trim_name(ctx.request.params["name"])
          raise Invalid, "A credential needs a name" if @name.blank?
        end

        def refusals(ctx)
          causes = [ state_refusal(nil) ]
          if @credential.name != @name && Credential.name_taken?(workspace_id: ctx.workspace.id, kind: @credential.kind,
            provider: @credential.provider, name: @name, except: @credential.id)
            causes << Refusal.new(code: "duplicate_name")
          end
          causes.compact
        end

        def perform(ctx)
          return if @credential.name == @name

          @credential.update!(name: @name, updated_at: ctx.at)
          ctx.emit("credential.renamed", subject: @credential, payload: {})
        end
      end
    end
  end
end
