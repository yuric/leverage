module Leverage
  module InboxItems
    module_function

    # Cancel open Needs you items about the task that no hold owns.
    def cancel_for_task(ctx, task)
      kind, id = ctx.actor
      InboxItem.where(workspace_id: task.workspace_id, about_kind: "task", about_id: task.id, state: "open",
        hold_id: nil).order(:opened_at).each do |item|
        item.update!(state: "resolved", resolved_by_kind: kind, resolved_by_id: id, resolved_at: ctx.at)
        ctx.emit("inbox.resolved", task: task, subject: item, payload: { choice: "cancel" })
      end
    end
  end
end
