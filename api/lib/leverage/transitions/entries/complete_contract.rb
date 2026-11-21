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
      # 422 invalid: criteria that do not end with the one independent
      # review (PRD Terms, Acceptance criterion), and a work reference with
      # sign-in details (L533).
      #
      # Params: id, and the CompleteContractRequest body. task.ready's
      # wait_cause is Candidates.wait_cause (HE-35): credential_limit when the
      # builders that would take the task wait for a limit, else null.
      #
      # Gated at task.before_ready (milestone 4 plan §2.1, RD-10, RD-37,
      # RE-6). Before the gate the open contract_incomplete hold closes
      # (L176: also when the command then waits, trace 16), and the owner's
      # request withdraws the task's open draft job (RD-37). A failed gate
      # performs the contract change alone (perform_contract_change: the
      # task stays in Backlog) and Gate opens contract_incomplete; a model
      # check makes it wait, and it completes later as its requester, the
      # owner or a planner (Transitions.run_as).
      class CompleteContract < Entry
        def load(ctx)
          @params = ctx.request.params
          @task = Task.find_by(id: @params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")

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

        # Before the gate: the open contract_incomplete hold closes first
        # (L176), and the owner's request withdraws an open draft job of
        # the task (RD-37).
        def before_gate(ctx)
          close_incomplete(ctx)
          return unless ctx.actor.first == "owner"

          Job.where(workspace_id: @task.workspace_id, task_id: @task.id, kind: "contract_draft", state: %w[queued claimed])
            .order(:queued_at, :id).each { |job| Jobs.withdraw(ctx, job) }
        end

        def perform(ctx)
          close_incomplete(ctx)
          change_contract(ctx, state: "ready")
          ctx.emit("task.ready", task: @task, payload: { wait_cause: Candidates.wait_cause(@task, ctx.at) })
          @result = nil
        end

        # The failed gate's effect (hooks.json hold_contract_incomplete,
        # RD-10): the contract change alone, the task staying in Backlog;
        # Gate opens contract_incomplete after it.
        def perform_contract_change(ctx)
          close_incomplete(ctx)
          change_contract(ctx, state: @task.state)
          @result = nil
        end

        private

        def close_incomplete(ctx)
          Holds.open_holds(@task).select { |hold| hold.reason == "contract_incomplete" }.each do |hold|
            Holds.close(ctx, hold: hold, task: @task)
          end
        end

        def change_contract(ctx, state:)
          written = ContractDiff.write(@task, Array(@params["criteria"]), at: ctx.at)
          actions = Actions.create_for(@task, Array(@params["actions"]))
          @task.update!(title: @params.fetch("title", @task.title), goal: @params.fetch("goal", @task.goal),
            details: @params["details"], work_reference: @params["work_reference"].presence,
            minimum_strength_rank: @params["minimum_strength_rank"], budget_cap: @params["budget_cap"],
            contract_version: @task.contract_version + 1, state: state)
          ctx.emit("task.contract_changed", task: @task,
            payload: { contract_version: @task.contract_version, minimum_strength_rank: @task.minimum_strength_rank,
                       added_criterion_ids: written.added_ids, reset_criterion_ids: written.reset_ids,
                       removed_criterion_ids: written.removed_ids, added_action_ids: actions.added_ids,
                       removed_action_ids: actions.removed_ids })
          Costs.cap_changed(ctx, @task)
        end
      end
    end
  end
end
