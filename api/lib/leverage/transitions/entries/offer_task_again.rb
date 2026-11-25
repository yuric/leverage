module Leverage
  module Transitions
    module Entries
      # Resolves the task's Unconfirmed action item. Its previous builder
      # gets a fresh lease for approved work when free or when it still
      # holds this task.
      class OfferTaskAgain < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such task")
          @builder = Seat.find_by(id: @task.builder_seat_id, workspace_id: ctx.workspace.id)
          Timers.apply_held_by(ctx, @builder) if available_builder? && @task.state == "finishing"
          @task.reload
          @hold = Holds.open_holds(@task).find { |hold| hold.reason == "action_unconfirmed" }
        end

        def refusals(ctx)
          guards = if @hold.nil?
            [ "not_held_action_unconfirmed" ]
          elsif !available_builder?
            %w[held_action_unconfirmed builder_seat_unavailable]
          elsif !Actions.approvals_complete?(@task)
            %w[held_action_unconfirmed builder_seat_enabled approvals_pending]
          else
            [ "held_action_unconfirmed", "builder_seat_enabled", "approvals_complete", builder_availability(ctx.at) ]
          end
          [ state_refusal(@task.state, guards) ].compact
        end

        def perform(ctx)
          lease_seat_id = @builder.id if @row.fetch("builder_lease") == "fresh"
          Holds.close(ctx, hold: @hold, task: @task, choice: "offer_again", lease_seat_id: lease_seat_id) do |closed|
            Finishing.settle(ctx, @task, by: closed)
          end
          @result = nil
        end

        private

        def available_builder? = @builder && Roles.acts_as?(@builder.role, "builder") && @builder.enabled && @builder.removed_at.nil?

        def builder_availability(at)
          return "builder_holds_task" if Finishing.builder_holds_task?(@task)
          return "builder_free" if Finishing.builder_free?(@task, lease: :action, at: at)

          "builder_busy"
        end
      end
    end
  end
end
