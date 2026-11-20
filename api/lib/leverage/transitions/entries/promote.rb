module Leverage
  module Transitions
    module Entries
      # promote (PRD Lifecycle L78; milestone 3 plan HE-24): the owner moves
      # an idea from the Imaginarium to the Backlog; task.promoted is
      # written, which closes the idea step and opens the contract's. Every
      # other state has no row: invalid_state. A hold does not stop it, as
      # it stops only a seat's work (L174).
      #
      # Params: id (the task).
      class Promote < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx) = [ state_refusal(@task.state) ].compact

        def perform(ctx)
          @task.update!(state: "backlog")
          ctx.emit("task.promoted", task: @task, payload: {})
          @result = nil
        end
      end
    end
  end
end
