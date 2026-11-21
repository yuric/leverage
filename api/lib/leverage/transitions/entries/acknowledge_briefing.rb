module Leverage
  module Transitions
    module Entries
      # acknowledge_briefing (PRD Lifecycle L84, The briefing L473; DB-11):
      # the holder acknowledges the hash of the briefing it read, under the
      # lease it holds. The acknowledgement row is kept per seat, per lease
      # (the event that granted it) and per hash; acknowledging the same hash
      # again under the same lease keeps the one row and writes the event
      # again. task.briefing_acknowledged has no subject. Not a work call,
      # and allowed under a hold. It clears a pending resume (L522).
      #
      # Refusals: the holder's (lease_expired, task_cancelled, not_holder,
      # forbidden), invalid_state, and briefing_changed for a hash that is
      # not the current one (the seat read an older briefing, L474).
      #
      # Params: id (the task), briefing_hash.
      class AcknowledgeBriefing < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          @hash = ctx.request.params["briefing_hash"].to_s
        end

        def refusals(_ctx)
          return [ "not_holder" ] if @task.state == "finishing" && @task.holder_seat_id.nil?

          codes = Eligibility.task_refusals(@task, @seat)
          codes << state_refusal(@task.state)
          codes << "briefing_changed" unless @hash == Briefing.hash_for(@task, seat: @seat)
          codes.compact
        end

        def perform(ctx)
          lease = Briefing.lease_event(@task, seat: @seat)
          BriefingAcknowledgement.find_or_create_by!(workspace_id: @task.workspace_id, seat_id: @seat.id,
            task_id: @task.id, review_id: nil, lease_event_id: lease.id, briefing_hash: @hash) do |row|
            row.acknowledged_at = ctx.at
          end
          @task.update!(resume_pending_since: nil) if @task.resume_pending_since
          ctx.emit("task.briefing_acknowledged", task: @task, payload: {})
          @result = nil
        end
      end
    end
  end
end
