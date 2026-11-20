module Leverage
  module Transitions
    module Entries
      # remove_seat (PRD L148, L823; milestone 2 plan IN-17, IN-40, SC-10):
      # writes seat.removed, sets removed_at, clears token_hash so the token
      # answers 401 from this moment, clears wanted_running and, for a seat
      # the app runs, queues stop_seat. A Working task the seat holds is
      # released to Ready (task.released, seat_removed, caused by
      # seat.removed), unless its lease has already passed its due time,
      # which is the lease timer's. A review the seat holds with a live or
      # paused lease is released too (review.released), so another reviewer
      # can claim it at once: a removed seat can never act on it again, and
      # a seat that connects on its own has no run whose stop would release
      # it (IF-21). A review lease past its due time is its timer's. A
      # pending submit, a pending pass or a provisional claim of the seat is
      # cancelled with invalid_state, after seat.removed and before the task
      # or the review is released (milestone 4 plan §2.1 rule 11,
      # SeatRuns.removed). A job the seat holds as a checker or a planner is
      # left to its run timeout. The row's other side events need holds of
      # later milestones and are not written.
      #
      # A removed or unknown seat is 404.
      #
      # Params: "id" (the seat).
      class RemoveSeat < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id, removed_at: nil)
          raise NotFound, "No such seat" unless @seat
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          @seat.update!(removed_at: ctx.at)
          removed = ctx.emit("seat.removed", subject: @seat, payload: {})
          stop = SeatRuns.removed(ctx, @seat, cause: removed)
          @result = { "helper_request_id" => stop&.id }
        end
      end
    end
  end
end
