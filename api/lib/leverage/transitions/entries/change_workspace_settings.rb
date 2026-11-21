require "json_schemer"

module Leverage
  module Transitions
    module Entries
      # Applies a partial update to the locked workspace (AP-39).
      class ChangeWorkspaceSettings < Entry
        SCHEMA = JSONSchemer.schema(Contract.openapi.fetch("components").fetch("schemas").fetch("ChangeWorkspaceSettingsRequest"))

        def load(ctx)
          raise Invalid, "The settings must match the contract." unless SCHEMA.valid?(ctx.request.params)
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          ctx.workspace.update!(ctx.request.params)
          ctx.emit("workspace.settings_changed")
          @result = Reads::WorkspaceSettings.from(ctx.workspace)
        end
      end
    end
  end
end
