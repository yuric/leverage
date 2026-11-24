module Leverage
  module Transitions
    module Entries
      # CR-10 and CR-22: schedule due reads and retain their receipts for
      # seven days. Neither operation writes an event.
      class UsageReadDue < Entry
        def perform(ctx)
          workspace_id = ctx.workspace.id
          UsageReads.expire_pickups(ctx.at, workspace_id: workspace_id)
          UsageReads.queue(ctx, UsageReads.due(ctx.at, workspace_id: workspace_id))
          UsageReads.purge(ctx.at, workspace_id: workspace_id)
        end
      end
    end
  end
end
