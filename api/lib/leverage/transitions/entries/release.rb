module Leverage
  module Transitions
    module Entries
      # release (PRD Lifecycle L103, L123, L505): the holder gives the task
      # back with a reason from the registry's list that a seat may choose.
      # From Working the task goes to Ready with no holder and no builder
      # (PRD Terms, Builder) and no lease; criteria that passed stay passed
      # (L123). task.released carries the reason. Allowed under a hold, and
      # the hold stays open; a hold bound to the seat (seat_paused,
      # credential_limit, credential_signed_out) closes when the seat loses
      # the task (SM-15), after task.released. None of those can open in
      # milestone 2. Release from Finishing, and of a provisional claim from
      # Ready, cannot be reached in milestone 2 (SC-3; no model check).
      #
      # 422 invalid for a reason only the app chooses (seat_disabled,
      # seat_removed).
      #
      # Params: id (the task), reason.
      class Release < Entry
        SEAT_BOUND = %w[seat_paused credential_limit credential_signed_out].freeze

        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          @reason = ctx.request.params["reason"]
          chosen_by_seat = Contract.registry.fetch("release_reasons").select { |entry| entry.fetch("chosen_by") == "seat" }
          raise Invalid, "A seat releases with one of its own reasons." unless chosen_by_seat.any? { |entry| entry.fetch("reason") == @reason }
        end

        def refusals(_ctx)
          (Eligibility.task_refusals(@task, @seat) << state_refusal(@task.state)).compact
        end

        def perform(ctx)
          Leases.end_lease(ctx, @task)
          @task.update!(state: @row.fetch("to") || @task.state, holder_seat_id: nil, builder_seat_id: nil,
            resume_pending_since: nil)
          ctx.emit("task.released", task: @task, payload: { reason: @reason, wait_cause: nil })
          Holds.open_holds(@task).select { |hold| SEAT_BOUND.include?(hold.reason) }.each do |hold|
            Holds.close(ctx, hold: hold, task: @task)
          end
          @result = nil
        end
      end
    end
  end
end
