module Leverage
  module Transitions
    module Entries
      # pause_seat (PRD L169, L258; milestone 3 plan HE-26): the owner
      # pauses a seat; seat.paused is written. The seat claims nothing more
      # (Eligibility). A task it holds with a live or paused lease is held
      # with seat_paused, opened by the app and caused by seat.paused; that
      # reason runs the lease clock (L121), so a pause longer than the
      # lease returns the task to Ready. No run is stopped: the runner meets
      # on_hold and waits (CL-31). A paused reviewer keeps the review it
      # holds, with no task hold (M1 G40). A task whose lease has passed its
      # due time is its timer's. The row's No reviewer is eligible side
      # events are milestone 4's (SM-42).
      #
      # A removed or unknown seat is 404; a seat already paused is
      # invalid_state.
      #
      # Params: id (the seat).
      class PauseSeat < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id, removed_at: nil)
          raise NotFound, "No such seat" unless @seat
        end

        def refusals(_ctx)
          causes = [ state_refusal(nil) ]
          causes << Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) if @seat.paused
          causes.compact
        end

        def perform(ctx)
          @seat.update!(paused: true)
          paused = ctx.emit("seat.paused", subject: @seat, payload: {})
          held_tasks(ctx).each { |task| Holds.open(ctx, task: task, reason: "seat_paused", cause_id: paused.id) }
          @result = nil
        end

        private

        # The tasks the seat holds with a live or paused lease.
        def held_tasks(ctx)
          Task.where(workspace_id: @seat.workspace_id, holder_seat_id: @seat.id).order(:created_at)
            .select { |task| SeatRuns.lease_live?(ctx, task) }
        end
      end
    end
  end
end
