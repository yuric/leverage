module Leverage
  module Transitions
    module Entries
      # The seat_run_placement timer (milestone 3 plan HD-4; timers.json): a
      # workspace timer fired by every sweep, as the app. It writes no event;
      # it only queues start_seat requests, through SeatRuns.ensure_run_on,
      # where SeatRuns.placement puts a run:
      #
      #   a running seat the app runs that holds nothing and whose run is
      #   not on its first available candidate is moved there, which is how
      #   an agent goes back to its own account once that has reset (L666);
      #   with no candidate available it is left where it is;
      #
      #   a seat wanted running whose last run ended for a limit or a
      #   sign-out, with no run now, is started again once the account its
      #   run belongs on is available; a seat whose task waits under a
      #   credential hold is left to the hold.
      #
      # A run that ended for any other reason is not started again until the
      # app is opened (IN-30), so a failing tool cannot loop on the owner's
      # quota. A seat the owner stopped or removed and a seat that connects
      # on its own are left alone.
      class SeatRunPlacement < Entry
        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          Seat.where(workspace_id: ctx.workspace.id, removed_at: nil, wanted_running: true).where.not(credential_id: nil)
            .order(:created_at, :id).each do |seat|
            if seat.run_state == "running"
              move_idle(ctx, seat)
            elsif seat.run_credential_id.nil? && SeatRuns::INTERRUPTIONS.include?(seat.run_stop_reason)
              start_again(ctx, seat)
            end
          end
          @result = nil
        end

        private

        def move_idle(ctx, seat)
          placement = SeatRuns.placement(seat, at: ctx.at)
          return unless placement.work.nil?

          first = Candidates.first_available(seat, nil, ctx.at)
          SeatRuns.ensure_run_on(ctx, seat, first, nil) if first
        end

        def start_again(ctx, seat)
          placement = SeatRuns.placement(seat, at: ctx.at)
          return unless placement.credential && Candidates.available?(placement.credential, ctx.at)

          SeatRuns.ensure_run_on(ctx, seat, placement.credential, placement.work)
        end
      end
    end
  end
end
