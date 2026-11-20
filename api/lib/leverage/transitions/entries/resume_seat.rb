module Leverage
  module Transitions
    module Entries
      # resume_seat (PRD L169, L258; milestone 3 plan HE-26): the owner
      # resumes a paused seat; seat.resumed is written, then the seat_paused
      # hold of each task the seat holds closes (hold.closed, the owner's,
      # caused by seat.resumed). With no hold left the seat's next GET
      # /v1/next answers resume (Holds.close). A hold the seat's lost task
      # still had was closed when it lost it (Holds.close_seat_bound). The
      # row's No reviewer is eligible side events are milestone 4's (SM-42).
      #
      # A removed or unknown seat is 404; a seat that is not paused is
      # invalid_state.
      #
      # Params: id (the seat).
      class ResumeSeat < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id, removed_at: nil)
          raise NotFound, "No such seat" unless @seat
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) unless @seat.paused
          causes.compact
        end

        def perform(ctx)
          @seat.update!(paused: false)
          resumed = ctx.emit("seat.resumed", subject: @seat, payload: {})
          Task.where(workspace_id: @seat.workspace_id, holder_seat_id: @seat.id).order(:created_at).each do |task|
            Holds.open_holds(task).select { |hold| hold.reason == "seat_paused" }.each do |hold|
              Holds.close(ctx, hold: hold, task: task, cause_id: resumed.id)
            end
          end
          @result = nil
        end
      end
    end
  end
end
