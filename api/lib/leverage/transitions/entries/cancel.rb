module Leverage
  module Transitions
    module Entries
      # cancel (PRD Lifecycle L106, L207; milestone 2 plan EN-30): the owner
      # cancels a task in any state but Done (and Cancelled). task.cancelled
      # is written first; then every open hold closes, oldest first, each
      # resolving its Needs you item with the choice cancel (Holds.close),
      # and any other open item about the task is resolved the same way. The
      # builder's lease and any review lease end; the task has no holder and
      # no builder (PRD Terms, Builder), and an open review loses its
      # reviewer, so both seats are free at once. The holder's next call on
      # the task is refused task_cancelled (Eligibility). Nothing pending,
      # no check, job or outward action exists to withdraw or revoke in
      # milestone 2 (SC-3, EN-5), so none of those events is written.
      #
      # Params: id (the task).
      class Cancel < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx) = [ state_refusal(@task.state) ].compact

        def perform(ctx)
          Leases.end_lease(ctx, @task)
          Review.where(workspace_id: @task.workspace_id, task_id: @task.id, verdict: nil).find_each do |review|
            Leases.end_lease(ctx, review)
            review.update!(reviewer_seat_id: nil)
          end
          @task.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil, resume_pending_since: nil)
          ctx.emit("task.cancelled", task: @task, payload: {})
          Holds.open_holds(@task).each { |hold| Holds.close(ctx, hold: hold, task: @task, choice: "cancel") }
          resolve_items(ctx)
          @result = nil
        end

        private

        # The task's open Needs you items that no hold owns.
        def resolve_items(ctx)
          InboxItem.where(workspace_id: @task.workspace_id, about_kind: "task", about_id: @task.id, state: "open",
            hold_id: nil).order(:opened_at).each do |item|
            kind, id = ctx.actor
            item.update!(state: "resolved", resolved_by_kind: kind, resolved_by_id: id, resolved_at: ctx.at)
            ctx.emit("inbox.resolved", task: @task, subject: item, payload: { choice: "cancel" })
          end
        end
      end
    end
  end
end
