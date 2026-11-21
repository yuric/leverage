module Leverage
  module Transitions
    module Entries
      # draft_contract (PRD L110, L802; milestone 4 plan RD-37, DB-31; trace
      # 16 command 9): the owner asks a planner to write a Backlog task's
      # contract. A contract_draft job is queued for the planner role
      # (Jobs.queue, job.queued) with its stored input, ContractDraftJobInput
      # without the material, which JobInputs builds when it is claimed. The
      # task stays in Backlog; the planner's result is the Complete contract
      # command (submit_job_result).
      #
      # Refused invalid_state outside Backlog (the state table) and while a
      # draft job of the task is queued or claimed (RD-37). A draft that
      # ended (finished, timed out twice, withdrawn) can be asked for again.
      # 404 for a task outside the workspace.
      #
      # Params: "id" (the task, from the path). Result: DraftContractResult.
      class DraftContract < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx)
          codes = [ state_refusal(@task.state) ]
          codes << Refusal.new(code: "invalid_state") if drafting?
          codes.compact
        end

        def perform(ctx)
          project = @task.project_id && Project.find_by(id: @task.project_id, workspace_id: @task.workspace_id)
          input = { "task_id" => @task.id, "project_id" => @task.project_id, "brief_version" => project&.brief_version || 0 }
          job = Jobs.queue(ctx, kind: "contract_draft", task: @task, target: @task, seat_role: "planner", input: input)
          @result = { "job_id" => job.id }
        end

        private

        # Whether a draft job of the task is queued or claimed.
        def drafting?
          Job.where(workspace_id: @task.workspace_id, task_id: @task.id, kind: "contract_draft", state: %w[queued claimed])
            .exists?
        end
      end
    end
  end
end
