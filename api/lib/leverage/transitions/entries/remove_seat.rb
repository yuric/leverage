module Leverage
  module Transitions
    module Entries
      # remove_seat (PRD L148, L823; milestone 2 plan IN-17, IN-40, SC-10):
      # writes seat.removed, sets removed_at, clears token_hash so the token
      # answers 401 from this moment, clears wanted_running and, for a seat
      # the app runs, queues stop_seat. A Working task the seat holds is
      # released to Ready (task.released, seat_removed, caused by
      # seat.removed), unless its lease has already passed its due time,
      # which is the lease timer's. A review the seat holds is not released
      # here: for a seat the app runs when the helper reports the run
      # stopped (IF-21), otherwise when its lease ends. The row's other side
      # events need holds and rules of later milestones and are not written.
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
          @seat.update!(removed_at: ctx.at, token_hash: nil, wanted_running: false)
          removed = ctx.emit("seat.removed", subject: @seat, payload: {})
          SeatRuns.release_working_task(ctx, @seat, reason: "seat_removed", cause: removed)
          stop = @seat.credential_id && SeatRuns.queue(ctx, "stop_seat", seat: @seat)
          @result = { "helper_request_id" => stop&.id }
        end
      end
    end
  end
end
