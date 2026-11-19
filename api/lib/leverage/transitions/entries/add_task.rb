module Leverage
  module Transitions
    module Entries
      # add_task (PRD Lifecycle L77; milestone 2 plan SC-3, SC-4, SC-8): the
      # owner adds a task to the Backlog; task.created is written.
      #
      # 422 invalid in this milestone: the Imaginarium (only Promote takes a
      # task out of it, milestone 3), a project (tasks have none until
      # milestone 5), outward actions (milestone 5), criteria (they are the
      # contract's: Complete contract writes them with task.contract_changed;
      # the app sends them there, L108), and a work reference with sign-in
      # details (L533). With no project, no project_paused hold can open.
      #
      # Params: title, goal, details, priority, work_reference, state, and
      # project_id, criteria and actions only when empty. Result: task_id.
      class AddTask < Entry
        def load(ctx)
          @params = ctx.request.params
          state = @params.fetch("state", "backlog")
          raise Invalid, "A task is added to the Backlog: nothing can promote it out of the Imaginarium yet." if state == "imaginarium"
          raise Invalid, "Tasks have no project in this milestone." if @params["project_id"]
          raise Invalid, "Criteria are part of the contract: send them with Complete contract." if @params["criteria"].present?
          raise Invalid, "Outward actions are not built yet." if @params["actions"].present?

          problem = LinkRules.work_reference_problem(@params["work_reference"])
          raise Invalid, problem if problem
        end

        def refusals(_ctx) = [ state_refusal(nil, [ "adds_to_backlog" ]) ].compact

        def perform(ctx)
          task = Task.create!(workspace_id: ctx.workspace.id, title: @params["title"], goal: @params["goal"],
            details: @params["details"], work_reference: @params["work_reference"].presence,
            priority: @params["priority"] || "normal", state: "backlog")
          ctx.emit("task.created", task: task, payload: { state: "backlog" })
          @result = { "task_id" => task.id }
        end
      end
    end
  end
end
