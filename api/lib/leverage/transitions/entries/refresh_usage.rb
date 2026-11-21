module Leverage
  module Transitions
    module Entries
      # Refresh asks for usage on every added active credential (CR-10).
      class RefreshUsage < Entry
        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          credentials = Credential.added.where(workspace_id: ctx.workspace.id, state: "active").order(:position)
          @result = { "helper_request_ids" => UsageReads.queue(ctx, credentials) }
        end
      end
    end
  end
end
