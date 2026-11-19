module Leverage
  module Transitions
    module Entries
      # report_run_started (milestone 2 plan IN-23; RunStartedReport): a run
      # started on a seat the app runs. seats.run_state becomes running and
      # nothing else changes; no event. The run must be on the seat's own
      # credential: a seat has exactly one in this milestone (PRD L590), and
      # a run on another is milestone 3's credential.switched, so it is 422
      # invalid. The helper may report on a removed seat (its stop may still
      # be queued). An unknown seat is 404; a seat that connects on its own
      # has no run the app starts: invalid_state.
      #
      # Params: "id" (the seat), "credential_id", "observed_at",
      # "tool_version" (neither of the last two is kept).
      class ReportRunStarted < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id)
          raise NotFound, "No such seat" unless @seat
          return unless @seat.credential_id
          return if ctx.request.params["credential_id"] == @seat.credential_id

          raise Invalid, "The run is not on the seat's credential"
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: "invalid_state") unless @seat.credential_id
          causes.compact
        end

        def perform(_ctx)
          @seat.update!(run_state: "running")
          @result = {}
        end
      end
    end
  end
end
