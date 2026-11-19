module Leverage
  module Transitions
    module Entries
      # report_run_stopped (PRD L121, L823, L914; milestone 2 plan IN-17,
      # IN-40, IF-21; RunStoppedReport): a run stopped, for whatever reason.
      # SeatRuns.run_stopped: the run state is stopped, the seat's token ends
      # (IN-17), and a review the seat holds is released (review.released,
      # as the app with the helper's key), so another reviewer can claim it.
      # A builder's task keeps its lease until the lease ends (L121). No
      # event of its own. A removed seat is reported on too: that is when a
      # review it kept is released (IN-40). An unknown seat is 404; a seat
      # that connects on its own has no run the app stops: invalid_state.
      #
      # Params: "id" (the seat), "credential_id", "observed_at",
      # "stop_reason" (limit and signed_out reasons act from milestone 3).
      class ReportRunStopped < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id)
          raise NotFound, "No such seat" unless @seat
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: "invalid_state") unless @seat.credential_id
          causes.compact
        end

        def perform(ctx)
          SeatRuns.run_stopped(ctx, @seat)
          @result = {}
        end
      end
    end
  end
end
