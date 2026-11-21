module Leverage
  # Project settings, ordered brief entries and each project's task holds.
  # The command holds the workspace lock for every write here.
  module Projects
    BATCH_SIZE = 200
    TERMINAL_STATES = %w[done cancelled].freeze
    PAUSE_REASON = "project_paused".freeze

    module_function

    def create(ctx, name:, goal: nil, budget: nil)
      project = Project.create!(workspace_id: ctx.workspace.id, name: name, goal: goal, budget: budget)
      ctx.emit("project.created", project_id: project.id)
      project
    end

    def add_spend(ctx, project_id, amount)
      project = Project.find_by!(id: project_id, workspace_id: ctx.workspace.id)
      project.update!(spent: Costs.total(project.spent, amount))
      project
    end

    def brief(project)
      return [] unless project

      brief_rows(project).order(:position).map do |entry|
        { "id" => entry.id, "project_id" => entry.project_id, "kind" => entry.kind, "text" => entry.text.to_s,
          "author_kind" => entry.author_kind, "author_id" => entry.author_id }
      end
    end

    def edit_brief(ctx, project, entries:)
      before = brief_rows(project).order(:position).to_a
      return if before.map { |entry| entry.values_at(:kind, :text) } == entries.map { |entry| entry.values_at("kind", "text") }

      kept, added, removed = compare_brief(before, entries)
      moved = kept.reject { |entry, position| entry.position == position }
      removed.each(&:destroy!)
      # The position index is immediate. Move retained rows that change
      # position out of the final range before writing their new positions.
      moved.each { |entry, position| entry.update!(position: before.size + entries.size + position) }
      moved.each { |entry, position| entry.update!(position: position) }
      inserted = added.map do |entry, position|
        brief_rows(project).create!(kind: entry.fetch("kind"), text: entry.fetch("text"), position: position,
          author_kind: ctx.actor.first, author_id: ctx.actor.last)
      end

      project.update!(brief_version: project.brief_version + 1)
      changed = removed + inserted
      changed = moved.keys if changed.empty?
      changed.each do |entry|
        ctx.emit("brief.changed", project_id: project.id, subject: entry, payload: { brief_version: project.brief_version })
      end
    end

    # Budget pauses have one project Needs you item even when there are
    # many task holds. Manual pauses do not open an item (DB-23).
    def pause(ctx, project, by:, cause: nil, rule_id: nil)
      budget = by == :budget
      kind, id = budget ? [ "app", nil ] : ctx.actor
      project.update!(paused: true)
      paused = ctx.emit("project.paused", project_id: project.id, actor_kind: kind, actor_id: id, cause_id: cause&.id)
      tasks = project_tasks(project).where.not(state: TERMINAL_STATES)
      each_task(tasks) do |task|
        open_hold(ctx, task, project, actor_kind: kind, actor_id: id, cause: paused, rule_id: rule_id)
      end
      open_budget_item(ctx, project, paused) if budget
      paused
    end

    def resume(ctx, project, choice: "resume_project")
      project.update!(paused: false)
      resumed = ctx.emit("project.resumed", project_id: project.id)
      tasks = project_tasks(project).where(id: open_holds(project).select(:task_id))
      each_task(tasks) do |task|
        from = ctx.events.size
        release_from(ctx, task, project, cause: resumed)
        # Closing the last hold can complete a waiting review. Its cost
        # can pause the project again in the same command.
        return resumed if ctx.events.drop(from).any? { |event| event.type == "project.paused" && event.project_id == project.id }
      end
      resolve_budget_item(ctx, project, choice)
      resumed
    end

    def change_budget(ctx, project, budget:)
      project.update!(budget: budget)
      ctx.emit("project.budget_changed", project_id: project.id, payload: { budget: project.budget&.to_f })
      return unless project.paused? && (project.budget.nil? || project.budget > project.spent)
      return unless last_pause(project)&.actor_kind == "app"

      resume(ctx, project, choice: "change_budget")
    end

    def change_task(ctx, task, **changes)
      task.update!(**changes)
      ctx.emit("task.changed", task: task,
        payload: { priority: task.priority, project_id: task.project_id, budget_cap: task.budget_cap&.to_f })
    end

    def hold_if_paused(ctx, task, cause: nil)
      return if task.project_id.nil? || TERMINAL_STATES.include?(task.state)

      project = Project.find_by!(id: task.project_id, workspace_id: task.workspace_id)
      return unless project.paused?

      kind, id = ctx.actor
      cause ||= ctx.events.reverse.find { |event| event.task_id == task.id && %w[task.created task.changed].include?(event.type) }
      open_hold(ctx, task, project, actor_kind: kind, actor_id: id, cause: cause)
    end

    def release_from(ctx, task, project, cause: nil)
      return unless project

      open_holds(project).where(task_id: task.id).order(:opened_at, :id).each do |hold|
        Holds.close(ctx, task: task, hold: hold, cause_id: cause&.id)
      end
    end

    def last_pause(project)
      Event.where(workspace_id: project.workspace_id, project_id: project.id, type: "project.paused").order(:seq).last
    end

    def brief_rows(project)
      BriefEntry.where(workspace_id: project.workspace_id, project_id: project.id)
    end

    def compare_brief(before, entries)
      available = before.group_by { |entry| entry.values_at(:kind, :text) }
      kept = {}
      added = []
      entries.each.with_index(1) do |entry, position|
        match = available[entry.values_at("kind", "text")]&.shift
        match ? kept[match] = position : added << [ entry, position ]
      end
      [ kept, added, before - kept.keys ]
    end

    def project_tasks(project)
      Task.where(workspace_id: project.workspace_id, project_id: project.id)
    end

    def each_task(tasks, &block)
      tasks.find_each(batch_size: BATCH_SIZE, cursor: [ :created_at, :id ], &block)
    end

    def open_holds(project)
      Hold.where(workspace_id: project.workspace_id, project_id: project.id, reason: PAUSE_REASON, closed_at: nil)
    end

    def open_hold(ctx, task, project, actor_kind:, actor_id:, cause:, rule_id: nil)
      return if open_holds(project).where(task_id: task.id).exists?

      Holds.open(ctx, task: task, reason: PAUSE_REASON, item: false, rule_id: rule_id, cause_id: cause&.id,
        actor_kind: actor_kind, actor_id: actor_id)
    end

    def budget_items(project)
      InboxItem.where(workspace_id: project.workspace_id, kind: Holds.needs_you_item(PAUSE_REASON).fetch("item"),
        about_kind: "project", about_id: project.id, state: "open")
    end

    def open_budget_item(ctx, project, cause)
      return if budget_items(project).exists?

      choices = Holds.needs_you_item(PAUSE_REASON).fetch("choices").map { |choice| choice.fetch("choice") }
      inbox = budget_items(project).create!(choices: choices, facts: {}, opened_at: ctx.at)
      ctx.emit("inbox.opened", project_id: project.id, subject: inbox, actor_kind: "app", actor_id: nil,
        cause_id: cause.id, payload: { kind: inbox.kind })
    end

    def resolve_budget_item(ctx, project, choice)
      kind, id = ctx.actor
      budget_items(project).each do |inbox|
        inbox.update!(state: "resolved", resolved_by_kind: kind, resolved_by_id: id, resolved_at: ctx.at)
        ctx.emit("inbox.resolved", project_id: project.id, subject: inbox, payload: { choice: choice })
      end
    end

    private_class_method :brief_rows, :compare_brief, :project_tasks, :each_task, :open_holds, :open_hold, :budget_items,
      :open_budget_item, :resolve_budget_item
  end
end
