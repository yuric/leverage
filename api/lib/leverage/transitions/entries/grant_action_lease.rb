module Leverage
  module Transitions
    module Entries
      class GrantActionLease < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such task")
        end

        def refusals(ctx)
          return [ "forbidden" ] unless ctx.request.by_app?

          refusal = state_refusal(@task.state)
          return [ refusal ] if refusal

          @action = Actions.first_approved_open(@task)
          ready = @action && Actions.approvals_complete?(@task) && @task.holder_seat_id.nil? &&
            !Eligibility.on_hold?(@task) && Finishing.builder_free?(@task, at: ctx.at)
          ready ? [] : [ "invalid_state" ]
        end

        def perform(ctx)
          Actions.grant_lease(ctx, @action, @task)
        end
      end
    end
  end
end
