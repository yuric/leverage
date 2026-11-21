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
      # the task is refused task_cancelled (Eligibility).
      #
      # A pending transition is cancelled first, with task_cancelled
      # (milestone 4 plan §2.1 rule 11, L919): PendingTransitions.cancel
      # withdraws its checks and jobs and closes the holds they opened,
      # before task.cancelled. Then the task's other pending checks and jobs
      # are withdrawn too (L207: "withdraws its pending checks and jobs";
      # milestone 4 review, finding 6): every check with no result and no
      # override (a warn rule's, which no command waits on) with its open
      # job, and every other job still queued or claimed (a contract
      # draft). After task.cancelled, Actions revokes the task's open
      # actions before the holds close (L208, trace 22).
      #
      # Params: id (the task).
      class Cancel < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx) = [ state_refusal(@task.state) ].compact

        def perform(ctx)
          pending = PendingTransitions.of(@task)
          PendingTransitions.cancel(ctx, pending, "task_cancelled") if pending
          withdraw_work(ctx)
          Leases.end_lease(ctx, @task)
          Review.where(workspace_id: @task.workspace_id, task_id: @task.id, verdict: nil).find_each do |review|
            Leases.end_lease(ctx, review)
            review.update!(reviewer_seat_id: nil)
          end
          @task.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil, resume_pending_since: nil)
          ctx.emit("task.cancelled", task: @task, payload: {})
          Actions.revoke_open(ctx, @task)
          Holds.open_holds(@task).each { |hold| Holds.close(ctx, hold: hold, task: @task, choice: "cancel") }
          InboxItems.cancel_for_task(ctx, @task)
          @result = nil
        end

        private

        def withdraw_work(ctx)
          RuleCheck.where(workspace_id: @task.workspace_id, task_id: @task.id, result: nil, overridden_at: nil)
            .order(:created_at, :id).each do |check|
            job = RuleChecks.open_job(check)
            RuleChecks.withdraw(ctx, check)
            Jobs.withdraw(ctx, job) if job
          end
          Job.where(workspace_id: @task.workspace_id, task_id: @task.id, state: RuleRecords::LIVE_JOBS)
            .order(:queued_at, :id).each { |job| Jobs.withdraw(ctx, job) }
        end
      end
    end
  end
end
