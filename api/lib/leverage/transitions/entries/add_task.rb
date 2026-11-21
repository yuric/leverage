module Leverage
  module Transitions
    module Entries
      # add_task (PRD Lifecycle L77; milestone 2 plan SC-3, SC-8; milestone
      # 3 plan HE-24): the owner adds a task to the Backlog, or to the
      # Imaginarium as an idea, now that Promote takes it out (SC-4 ends);
      # task.created names the state.
      #
      # A project_id names a project of the workspace, and the task is that
      # project's (RD-52). A paused project holds the new task.
      #
      # 422 invalid in this milestone: another state, a project_id that
      # names no project of the workspace, criteria (Complete contract
      # writes them, L108), and a work reference with sign-in details (L533).
      #
      # Params: title, goal, details, priority, work_reference, state,
      # project_id, actions, and criteria only when empty. Result:
      # task_id.
      class AddTask < Entry
        # The state-table guard of each state a task may be added in.
        GUARDS = { "imaginarium" => "adds_to_imaginarium", "backlog" => "adds_to_backlog" }.freeze

        def load(ctx)
          @params = ctx.request.params
          @state = @params.fetch("state", "backlog")
          raise Invalid, "A task is added to the Imaginarium or the Backlog." unless GUARDS.key?(@state)
          @project = @params["project_id"] && Project.find_by(id: @params["project_id"], workspace_id: ctx.workspace.id)
          raise Invalid, "No such project in this workspace." if @params["project_id"] && @project.nil?
          raise Invalid, "Criteria are part of the contract: send them with Complete contract." if @params["criteria"].present?

          problem = LinkRules.work_reference_problem(@params["work_reference"])
          raise Invalid, problem if problem
        end

        def refusals(_ctx) = [ state_refusal(nil, [ GUARDS.fetch(@state) ]) ].compact

        def perform(ctx)
          task = Task.create!(workspace_id: ctx.workspace.id, project_id: @project&.id, title: @params["title"], goal: @params["goal"],
            details: @params["details"], work_reference: @params["work_reference"].presence,
            priority: @params["priority"] || "normal", state: @state)
          Actions.create_for(task, Array(@params["actions"]))
          ctx.emit("task.created", task: task, payload: { state: @state })
          Projects.hold_if_paused(ctx, task)
          @result = { "task_id" => task.id }
        end
      end
    end
  end
end
