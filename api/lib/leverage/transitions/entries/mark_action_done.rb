module Leverage
  module Transitions
    module Entries
      # Marking an unconfirmed action done closes its hold. That close
      # carries any fresh lease for the approved actions still open.
      class MarkActionDone < Entry
        def load(ctx)
          @action = Action.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such action")
          @task = Task.find_by!(id: @action.task_id, workspace_id: ctx.workspace.id)
          if Timers.apply_task_timers(ctx, [ @task ]).any?
            @action.reload
            @task.reload
          end
          @hold = Holds.open_holds(@task).find { |hold| hold.reason == "action_unconfirmed" }
        end

        def refusals(_ctx)
          guards = if @hold.nil?
            [ "not_held_action_unconfirmed" ]
          elsif markable?
            # All rows for an unconfirmed, markable action accept. The
            # remaining actions determine whether the close gives a lease.
            %w[held_action_unconfirmed not_last_open_action approvals_pending]
          else
            []
          end
          [ state_refusal(@task.state, guards) ].compact
        end

        def perform(ctx)
          last = Actions.last_open?(@action)
          Actions.mark_done(ctx, @action)
          lease_seat_id = @task.builder_seat_id if !last && Actions.approvals_complete?(@task) && Finishing.builder_free?(@task, lease: :action)

          closed = nil
          Holds.close(ctx, hold: @hold, task: @task, choice: "mark_done", lease_seat_id: lease_seat_id) do |event|
            closed = event
            Finishing.settle(ctx, @task, by: event) if last || lease_seat_id
          end
          Finishing.settle(ctx, @task, by: closed) unless last || lease_seat_id
          @result = nil
        end

        private

        def markable?
          Contract.state_machine.dig("action_machine", "transitions").any? do |move|
            move.fetch("commands").include?(command) && move.fetch("from").include?(@action.state)
          end
        end
      end
    end
  end
end
