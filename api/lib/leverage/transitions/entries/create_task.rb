module Leverage
  module Transitions
    module Entries
      # The seat's Add task starts in Backlog, then completes its contract
      # through the same gate as the owner and the planner (UX-11).
      class CreateTask < AddTask
        def load(ctx)
          @seat = Seat.find_by!(workspace_id: ctx.workspace.id, id: ctx.request.caller_id)
          return unless Permissions.creates?(@seat)

          @work = AgentTasks.held_work(@seat, at: ctx.at)
          body = ctx.request.params
          params = body.slice("title", "details", "priority", "project_id", "work_reference")
          if @work
            project_id = AgentTasks.task_of(@work)&.project_id
            if params["project_id"] && !params["project_id"].casecmp?(project_id.to_s)
              raise Invalid, "A task you add while you work goes into the project of that work."
            end
            params["project_id"] = project_id
          end
          load_task(ctx, params)
          @contract = body.slice("title", "details", "criteria", "work_reference")
        end

        def refusals(ctx)
          return [ "forbidden" ] unless Permissions.creates?(@seat)

          reason = AgentTasks.limit(@seat, @work, at: ctx.at)
          return [ Refusal.new(code: "add_task_limit", reason: reason) ] if reason

          super
        end

        def perform(ctx)
          super
          id = @result.fetch("task_id")
          outcome = Transitions.run_as(ctx, "complete_contract", requester: @seat, key: ctx.request.key, params: @contract.merge("id" => id))
          raise Invalid, "The new task's contract could not be completed." if outcome == :refused

          @result = { "task_id" => id, "state" => Task.find(id).state }
        end
      end
    end
  end
end
