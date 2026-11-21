module Leverage
  module Transitions
    module Entries
      class ReportCost < Entry
        def load(ctx)
          @params = ctx.request.params
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: @params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx)
          (Eligibility.task_refusals(@task, @seat) << state_refusal(@task.state)).compact
        end

        # The hook runs from Costs, after the event and the new sums exist.
        def hook = nil

        def perform(ctx)
          Costs.report(ctx, task: @task, subject: nil, tokens: @params.fetch("tokens"), spend: @params.fetch("spend"))
        end
      end
    end
  end
end
