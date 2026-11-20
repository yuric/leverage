module Leverage
  module Transitions
    module Entries
      # heartbeat (PRD L119, L263, L495, L546): the holder renews its lease
      # (Leases.renew: one lease length from now, or, while a hold pauses
      # it, still paused with the whole length left). No event. Not a work
      # call; allowed under a hold and while a transition is pending. A lease
      # past its due time has already been ended by its timer (Timers runs
      # first), so the seat is refused lease_expired (EN-15). It clears a
      # pending resume.
      #
      # Result: HeartbeatResult. lease_due_at is the due time, or, for a
      # paused lease, the time it would be due if its clock ran from now.
      #
      # Params: id (the task).
      class Heartbeat < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx)
          (Eligibility.task_refusals(@task, @seat) << state_refusal(nil)).compact
        end

        def perform(ctx)
          Leases.renew(ctx, @task)
          @task.update!(resume_pending_since: nil) if @task.resume_pending_since
          @result = { "lease_due_at" => self.class.due_at(ctx, @task).utc.iso8601(6) }
        end

        # The lease's due time, or a paused lease's as if it ran from now.
        def self.due_at(ctx, subject)
          subject.lease_due_at || (ctx.at + subject.lease_time_left_while_paused.to_f)
        end
      end
    end
  end
end
