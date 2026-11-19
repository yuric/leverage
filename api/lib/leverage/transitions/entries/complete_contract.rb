module Leverage
  module Transitions
    module Entries
      # complete_contract (PRD Lifecycle L80, L175; milestone 2 plan SC-3):
      # from Backlog to Ready at task.before_ready. The criteria are written
      # in order, task.contract_changed and task.ready follow. An open
      # contract_incomplete hold closes first (L175); the command is allowed
      # under a hold. The task's earlier criteria, if any, are removed: in
      # milestone 2 a Backlog task has none, since nothing returns a task to
      # the Backlog before Edit contract (milestone 3).
      #
      # 422 invalid: an outward action (SC-3), criteria that do not end with
      # the one independent review (PRD Terms, Acceptance criterion: "The
      # last one is always the independent review"), and a work reference
      # with sign-in details (L533).
      #
      # Params: id, and the CompleteContractRequest body. task.ready's
      # wait_cause is null: no credential can be limited before milestone 3.
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
          removed = Criterion.where(task_id: @task.id, removed_at: nil).order(:position).to_a
          removed.each { |criterion| criterion.update!(removed_at: ctx.at) }
          added = Array(@params["criteria"]).each_with_index.map do |criterion, index|
            Criterion.create!(workspace_id: @task.workspace_id, task_id: @task.id, position: index + 1,
              kind: criterion.fetch("kind"), text: criterion.fetch("text"))
          end
          @task.update!(title: @params.fetch("title", @task.title), goal: @params.fetch("goal", @task.goal),
            details: @params["details"], work_reference: @params["work_reference"].presence,
            minimum_strength_rank: @params["minimum_strength_rank"], budget_cap: @params["budget_cap"],
            contract_version: @task.contract_version + 1, state: "ready")
          ctx.emit("task.contract_changed", task: @task,
            payload: { contract_version: @task.contract_version, minimum_strength_rank: @task.minimum_strength_rank,
                       added_criterion_ids: added.map(&:id), reset_criterion_ids: [],
                       removed_criterion_ids: removed.map(&:id), added_action_ids: [], removed_action_ids: [] })
          ctx.emit("task.ready", task: @task, payload: { wait_cause: nil })
          @result = nil
        end
      end
    end
  end
end
