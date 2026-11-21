module Leverage
  module Transitions
    module Entries
      class ApproveAction < Entry
        def load(ctx)
          @action = Action.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such action")
          @task = Task.find(@action.task_id)
          @holds = Actions.owner_approval_holds(@action) if ctx.request.caller_kind == "owner"
        end

        def refusals(ctx)
          asked = Actions.allows?(@action, command) && approval_asked_of?(ctx)
          guards = if asked
            [ "approval_asked_of_caller", *approval_guards(ctx.at) ]
          else
            [ "approval_not_asked_of_caller" ]
          end
          [ state_refusal(@task.state, guards) ].compact
        end

        def perform(ctx)
          event = Actions.approve(ctx, @action, by: ctx.actor)
          Array(@holds).each do |hold|
            Holds.close(ctx, hold: hold, task: @task, choice: "approve")
          end
          Finishing.settle(ctx, @task.reload, by: event)
        end

        private

        def approval_asked_of?(ctx)
          case ctx.request.caller_kind
          when "owner" then @holds.any?
          when "seat" then Actions.approval_job_check(ctx, @action)&.effect == "approved"
          else false
          end
        end

        def approval_guards(at)
          return [ "approvals_pending" ] unless Actions.approvals_complete?(@task, except: @action)

          [ "approvals_complete", Finishing.builder_free?(@task, at: at) ? "builder_free" : "builder_busy" ]
        end
      end
    end
  end
end
