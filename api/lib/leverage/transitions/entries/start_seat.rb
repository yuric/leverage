module Leverage
  module Transitions
    module Entries
      # start_seat (PRD L590-L591; milestone 2 plan IN-23, IN-30; milestone 3
      # plan HD-1): marks a seat the app runs wanted running and queues
      # start_seat where SeatRuns.placement puts its run, with the role, the
      # provider, model and effort of that credential and the work to
      # continue; no event. The seat's token is issued when the helper picks
      # the request up (issue_seat_token). A seat whose task waits under a
      # credential hold gets no request until the hold closes (HE-21): the
      # answer's helper_request_id is then null.
      # While a start of the seat is still unfinished and the seat is still
      # wanted running, no second one is queued: the answer names that
      # request, so one seat never has two runs racing for its token. A
      # start that the owner's Stop came after (the seat is no longer
      # wanted running) is stale, for instance one whose result the helper
      # never reported: it is failed, as a new helper token fails it, and a
      # new request is queued, so Start never answers a request nobody will
      # finish.
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
          request = SeatRuns.owner_start(ctx, @seat)
          @result = { "helper_request_id" => request&.id }
        end
      end
    end
  end
end
