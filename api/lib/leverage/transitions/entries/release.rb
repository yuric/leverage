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
      # the task (SM-15), after task.released (Holds.close_seat_bound).
      # The wait_ready step that opens has the cause of HE-35
      # (Candidates.wait_cause, asked once the seat holds nothing): on
      # task.released when the task had no hold, else on the hold.closed
      # that leaves it with none (milestone 3 plan §2.1, changed entries).
      #
      # A waiting command of the releasing seat is ended first, with
      # invalid_state (milestone 4 plan §2.1 rule 11, RE-4): a pending
      # submit from Working, or a provisional claim from Ready (SM-13: the
      # claimant holds the task in Ready with no lease, RE-5, and releasing
      # it writes task.released with its reason and leaves it Ready with no
      # holder). PendingTransitions.cancel withdraws its checks and jobs
      # before task.released. Release from Finishing cannot be reached
      # before milestone 5 (SC-3, HS-3).
      #
      # 422 invalid for a reason only the app chooses (seat_disabled,
      # seat_removed).
      #
      # Params: id (the task), reason.
      class Release < Entry
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
          pending = PendingTransitions.of(@task)
          PendingTransitions.cancel(ctx, pending, "invalid_state") if pending
          held = Holds.held?(@task)
          Leases.end_lease(ctx, @task)
          @task.update!(state: @row.fetch("to") || @task.state, holder_seat_id: nil, builder_seat_id: nil,
            resume_pending_since: nil)
          wait_cause = Candidates.wait_cause(@task, ctx.at) if @task.state == "ready"
          released = ctx.emit("task.released", task: @task,
            payload: { reason: @reason, wait_cause: (wait_cause unless held) })
          Holds.close_seat_bound(ctx, @task, cause: released, wait_cause: wait_cause)
          @result = nil
        end
      end
    end
  end
end
