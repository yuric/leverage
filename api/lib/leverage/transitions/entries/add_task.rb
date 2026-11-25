module Leverage
  module Transitions
    module Entries
      # add_task (PRD Lifecycle L77; milestone 2 plan SC-3, SC-8; milestone
      # 3 plan HE-24): the owner adds a task to the Backlog, or to the
      # Ideas as an idea, now that Promote takes it out (SC-4 ends);
      # task.created names the state.
      #
      # A project_id names a project of the workspace, and the task is that
      # project's (RD-52). A paused project holds the new task.
      #
      # 422 invalid in this milestone: another state, a project_id that
      # names no project of the workspace, criteria except for an Imaginarium
      # idea, and a work reference with sign-in details (L533).
      #
      # Params: title, details, priority, work_reference, state,
      # project_id, actions, and the optional Imaginarium source. An idea
      # with a source takes its ready-made criteria for later promotion.
      # Result: task_id.
      class AddTask < Entry
        # The state-table guard of each state a task may be added in.
        GUARDS = { "ideas" => "adds_to_ideas", "backlog" => "adds_to_backlog" }.freeze

        def load(ctx)
          @params = ctx.request.params
          @state = @params.fetch("state", "backlog")
          raise Invalid, "A task is added to Ideas or the Backlog." unless GUARDS.key?(@state)

          @imaginarium = @params["imaginarium"]
          @project = find_project(ctx.workspace)
          @criteria = Array(@params["criteria"])
          validate_criteria

          problem = LinkRules.work_reference_problem(@params["work_reference"])
          raise Invalid, problem if problem
        end

        def refusals(_ctx) = [ state_refusal(nil, [ GUARDS.fetch(@state) ]) ].compact

        def perform(ctx)
          task = Task.create!(workspace_id: ctx.workspace.id, project_id: @project&.id, title: @params["title"],
            details: @params["details"], work_reference: @params["work_reference"].presence,
            priority: @params["priority"] || "normal", state: @state,
            imaginarium_entry_id: @imaginarium&.fetch("entry_id"), imaginarium_catalog_version: @imaginarium&.fetch("catalog_version"))
          definitions = Actions.create_for(task, Array(@params["actions"]))
          payload = { state: @state, added_action_ids: definitions.added_ids }
          if @imaginarium
            payload[:imaginarium_entry] = task.imaginarium_entry_id
            payload[:added_criterion_ids] = @criteria.empty? ? [] : ContractDiff.write(task, @criteria, at: ctx.at).added_ids
          end
          ctx.emit("task.created", task: task, payload: payload, schema_version: @imaginarium ? 2 : 1)
          Projects.hold_if_paused(ctx, task)
          @result = { "task_id" => task.id }
        end

        private

        def find_project(workspace)
          project_id = @params["project_id"]
          if @imaginarium
            validate_source
            if project_id && !project_id.casecmp?(workspace.imaginarium_project_id.to_s)
              raise Invalid, "A gallery task goes to the Imaginarium project."
            end
            return Project.find_by(id: workspace.imaginarium_project_id, workspace_id: workspace.id, content_deleted_at: nil) ||
              raise(Invalid, "The Imaginarium project is unavailable.")
          end
          return unless project_id

          Project.find_by(id: project_id, workspace_id: workspace.id) || raise(Invalid, "No such project in this workspace.")
        end

        def validate_source
          entry, version = @imaginarium.values_at("entry_id", "catalog_version") if @imaginarium.is_a?(Hash)
          return if Contract.list("imaginarium_entries").include?(entry) &&
            version.is_a?(Integer) && version.between?(1, 2_147_483_647)

          raise Invalid, "An Imaginarium task needs a catalog entry and version."
        end

        def validate_criteria
          if @imaginarium && @state == "ideas"
            kinds = @criteria.map { |criterion| criterion["kind"] }
            return if (3..5).cover?(kinds.size) && kinds.last == "review" && kinds[0...-1].all?("build")

            raise Invalid, "An Imaginarium idea needs its Done when checks and a final independent review."
          end
          raise Invalid, "Criteria are part of the contract: send them with Complete contract." if @criteria.present?
        end
      end
    end
  end
end
