module Leverage
  module Transitions
    module Entries
      class GrantAccess < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          Holds.open_holds(@task).each do |hold|
            Holds.close(ctx, hold: hold, task: @task, choice: "mark_access_granted") if hold.reason == "access"
          end
        end
      end
    end
  end
end
