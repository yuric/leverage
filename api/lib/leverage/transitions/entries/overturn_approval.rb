module Leverage
  module Transitions
    module Entries
      # Stops an open action the orchestrator approved. An action that
      # already went out keeps its state and gets one audit event (AP-13).
      class OverturnApproval < Entry
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
          [ state_refusal(@task.state, approval_guards) ].compact
        end

        def perform(ctx)
          if @action.state == "done"
            Actions.record_overturn(ctx, @action)
          else
            Actions.stop(ctx, @action, by: ctx.actor)
          end
          @result = nil
        end

        private

        def approval_guards
          return [] unless @action.approved_by_kind == "seat" && @action.approved_by_id

          case @action.state
          when "approved", "started" then [ "approved_action_open" ]
          when "done"
            [ "approved_action_done", overturned? ? "approval_already_overturned" : "approval_not_yet_overturned" ]
          else []
          end
        end

        def overturned?
          Event.exists?(workspace_id: @task.workspace_id, task_id: @task.id, type: "action.overturn_recorded",
            subject_kind: "action", subject_id: @action.id)
        end
      end
    end
  end
end
