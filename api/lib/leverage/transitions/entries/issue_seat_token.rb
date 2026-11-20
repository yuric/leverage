module Leverage
  module Transitions
    module Entries
      # issue_seat_token (milestone 2 plan IN-11, IN-17, IN-18, PK-7): the
      # helper, holding a start_seat request, asks for the seat's fresh
      # token. A new token's digest replaces seats.token_hash, which ends the
      # previous token, and the token is returned once, in once: never in
      # the commands row, the helper request or an event (none is written).
      #
      # The path id names a start_seat request of the helper's workspace,
      # else 404. A request that has finished or failed, or a seat that has
      # been removed, is refused invalid_state: the run it was for is over.
      class IssueSeatToken < Entry
        # The helper request states a run can still be started from.
        OPEN_STATES = %w[queued picked_up].freeze

        def load(ctx)
          @helper_request = HelperRequest.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id,
            kind: "start_seat")
          @seat = @helper_request && Seat.find_by(id: @helper_request.seat_id, workspace_id: ctx.workspace.id)
          raise NotFound, "No such start_seat request" unless @seat
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: "invalid_state") if @seat.removed_at || !OPEN_STATES.include?(@helper_request.state)
          causes.compact
        end

        def perform(_ctx)
          token = SeatRuns.issue_token(@seat, @helper_request)
          @result = { "helper_request_id" => @helper_request.id, "seat_id" => @seat.id }
          @once = { "seat_token" => token }
        end
      end
    end
  end
end
