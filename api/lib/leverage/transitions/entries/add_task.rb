module Leverage
  module Transitions
    module Entries
      # add_task (PRD Lifecycle L77; milestone 2 plan SC-3, SC-8; milestone
      # 3 plan HE-24): the owner adds a task to the Backlog, or to the
      # Imaginarium as an idea, now that Promote takes it out (SC-4 ends);
      # task.created names the state.
      #
      # 422 invalid in this milestone: another state, a project (tasks have
      # none until milestone 5), outward actions (milestone 5), criteria
      # (they are the contract's: Complete contract writes them with
      # task.contract_changed; the app sends them there, L108), and a work
      # reference with sign-in details (L533). With no project, no
      # project_paused hold can open.
      #
      # Params: title, goal, details, priority, work_reference, state, and
      # project_id, criteria and actions only when empty. Result: task_id.
      class AddTask < Entry
        # The state-table guard of each state a task may be added in.
        GUARDS = { "imaginarium" => "adds_to_imaginarium", "backlog" => "adds_to_backlog" }.freeze

        def load(ctx)
          @params = ctx.request.params
          @state = @params.fetch("state", "backlog")
          raise Invalid, "A task is added to the Imaginarium or the Backlog." unless GUARDS.key?(@state)
          raise Invalid, "Tasks have no project in this milestone." if @params["project_id"]
          raise Invalid, "Criteria are part of the contract: send them with Complete contract." if @params["criteria"].present?
          raise Invalid, "Outward actions are not built yet." if @params["actions"].present?

          problem = LinkRules.work_reference_problem(@params["work_reference"])
          raise Invalid, problem if problem
        end

        def refusals(_ctx) = [ state_refusal(nil, [ GUARDS.fetch(@state) ]) ].compact

        def perform(ctx)
          task = Task.create!(workspace_id: ctx.workspace.id, title: @params["title"], goal: @params["goal"],
            details: @params["details"], work_reference: @params["work_reference"].presence,
            priority: @params["priority"] || "normal", state: @state)
          ctx.emit("task.created", task: task, payload: { state: @state })
          @result = { "task_id" => task.id }
        end
      end
    end
  end
end
