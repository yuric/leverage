module Leverage
  module Transitions
    module Entries
      # The action writer withdraws the action's checks and approval job.
      # The entry resolves the holds the waive answers (SM-10 and SM-11).
      class WaiveAction < Entry
        def load(ctx)
          @action = Action.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such action")
          @task = Task.find_by!(id: @action.task_id, workspace_id: ctx.workspace.id)
          if Timers.apply_task_timers(ctx, [ @task ]).any?
            @action.reload
            @task.reload
          end
        end

        def refusals(_ctx)
          # Every listed Finishing row accepts a waivable action. Which
          # branch applies depends on the actions left by the waive.
          guards = waivable? ? [ "not_last_open_action", "approvals_pending" ] : []
          [ state_refusal(@task.state, guards) ].compact
        end

        def perform(ctx)
          last = Actions.last_open?(@action)
          waived = Actions.waive(ctx, @action)
          Finishing.settle(ctx, @task, by: waived) if last
          answered_holds.each { |hold| Holds.close(ctx, hold: hold, task: @task, choice: "waive") }
          Actions.action_check_error_holds(@action).each { |hold| Holds.close(ctx, hold: hold, task: @task) }
          Finishing.settle(ctx, @task, by: waived) unless last
          @result = nil
        end

        private

        def waivable?
          Contract.state_machine.dig("action_machine", "transitions").any? do |move|
            move.fetch("commands").include?(command) && move.fetch("from").include?(@action.state)
          end
        end

        def answered_holds
          open = Holds.open_holds(@task).select { |hold| %w[action_stopped owner_approval action_unconfirmed].include?(hold.reason) }
          facts = InboxItem.where(workspace_id: @task.workspace_id, hold_id: open.map(&:id), state: "open").pluck(:hold_id, :facts).to_h
          open.select do |hold|
            item = facts.fetch(hold.id, {})
            hold.action_id == @action.id || item["action_id"] == @action.id || Array(item["action_ids"]).include?(@action.id)
          end
        end
      end
    end
  end
end
