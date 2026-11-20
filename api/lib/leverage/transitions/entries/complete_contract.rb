module Leverage
  module Transitions
    module Entries
      # complete_contract (PRD Lifecycle L80, L175, L205; milestone 2 plan
      # SC-3; milestone 3 plan HE-25 (i), HE-35): from Backlog to Ready at
      # task.before_ready. The criteria are written in order,
      # task.contract_changed and task.ready follow. An open
      # contract_incomplete hold closes first (L175); the command is allowed
      # under a hold. A task Edit contract returned to the Backlog already
      # has criteria: they are compared with the contract by position and
      # kind as Edit contract compares them (ContractDiff), so a criterion
      # whose position, kind and text are unchanged is kept with its state,
      # and task.contract_changed lists only what was added, reset or
      # removed (trace 15; HM-49, "What has passed stays passed").
      #
      # 422 invalid: an outward action (SC-3), criteria that do not end with
      # the one independent review (PRD Terms, Acceptance criterion: "The
      # last one is always the independent review"), and a work reference
      # with sign-in details (L533).
      #
      # Params: id, and the CompleteContractRequest body. task.ready's
      # wait_cause is Candidates.wait_cause (HE-35): credential_limit when the
      # builders that would take the task wait for a limit, else null.
      class CompleteContract < Entry
        def load(ctx)
          @params = ctx.request.params
          @task = Task.find_by(id: @params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          raise Invalid, "Outward actions are not built yet." if @params["actions"].present?

          kinds = Array(@params["criteria"]).map { |criterion| criterion["kind"] }
          unless kinds.last == "review" && kinds.count("review") == 1
            raise Invalid, "The last criterion, and only the last, is the independent review."
          end

          problem = LinkRules.work_reference_problem(@params["work_reference"])
          raise Invalid, problem if problem
        end

        def refusals(_ctx) = [ state_refusal(@task.state) ].compact

        def gate_request_fields(_ctx)
          super.merge(task_id: @task.id, project_id: @task.project_id, round: @task.round)
        end

        def perform(ctx)
          Holds.open_holds(@task).select { |hold| hold.reason == "contract_incomplete" }.each do |hold|
            Holds.close(ctx, hold: hold, task: @task)
          end
          written = ContractDiff.write(@task, Array(@params["criteria"]), at: ctx.at)
          @task.update!(title: @params.fetch("title", @task.title), goal: @params.fetch("goal", @task.goal),
            details: @params["details"], work_reference: @params["work_reference"].presence,
            minimum_strength_rank: @params["minimum_strength_rank"], budget_cap: @params["budget_cap"],
            contract_version: @task.contract_version + 1, state: "ready")
          ctx.emit("task.contract_changed", task: @task,
            payload: { contract_version: @task.contract_version, minimum_strength_rank: @task.minimum_strength_rank,
                       added_criterion_ids: written.added_ids, reset_criterion_ids: written.reset_ids,
                       removed_criterion_ids: written.removed_ids, added_action_ids: [], removed_action_ids: [] })
          ctx.emit("task.ready", task: @task, payload: { wait_cause: Candidates.wait_cause(@task, ctx.at) })
          @result = nil
        end
      end
    end
  end
end
