module Leverage
  module Transitions
    module Entries
      # start_seat (PRD L590-L591; milestone 2 plan IN-23, IN-30): marks a
      # seat the app runs wanted running and queues start_seat with the
      # seat's role, provider, model and effort; no event. The seat's token
      # is issued when the helper picks the request up (issue_seat_token).
      # While a start of the seat is still unfinished no second one is
      # queued: the answer names that request, so one seat never has two
      # runs racing for its token.
      #
      # A removed or unknown seat is 404; a seat that connects on its own
      # has no run the app starts: invalid_state.
      #
      # Params: "id" (the seat).
      class StartSeat < Entry
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
          @seat.update!(wanted_running: true)
          request = HelperRequest.where(seat_id: @seat.id, kind: "start_seat", state: %w[queued picked_up])
            .order(:requested_at).first
          request ||= SeatRuns.queue(ctx, "start_seat", seat: @seat, params: SeatRuns.start_params(@seat))
          @result = { "helper_request_id" => request.id }
        end
      end
    end
  end
end
