module Leverage
  module Transitions
    module Entries
      # stop_seat (PRD L590; milestone 2 plan IN-17, IN-23, IN-30): a seat
      # the app runs is no longer wanted running, and stop_seat is queued;
      # no event. The seat's token ends when the helper reports the run
      # stopped (report_run_stopped), so the runner can still release what
      # it holds on its way out (CL-23).
      #
      # A removed or unknown seat is 404; a seat that connects on its own
      # has no run the app stops: invalid_state.
      #
      # Params: "id" (the seat).
      class StopSeat < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id, removed_at: nil)
          raise NotFound, "No such seat" unless @seat
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: "invalid_state") unless @seat.credential_id
          causes.compact
        end

        def perform(ctx)
          @seat.update!(wanted_running: false)
          request = SeatRuns.queue(ctx, "stop_seat", seat: @seat)
          @result = { "helper_request_id" => request.id }
        end
      end
    end
  end
end
