module Leverage
  module Reads
    # The projects and their ordered briefs at one point in the log (AP-26).
    module Projects
      module_function

      def call(workspace_id)
        Snapshot.call(workspace_id) do
          projects = Project.where(workspace_id: workspace_id).order(:created_at, :id).to_a
          ids = projects.map(&:id)
          briefs = BriefEntry.where(workspace_id: workspace_id, project_id: ids).order(:position).group_by(&:project_id)
          open = Task.where(workspace_id: workspace_id, project_id: ids).where.not(state: %w[done cancelled]).group(:project_id).count
          pauses = pause_actors(workspace_id, projects.select(&:paused).map(&:id))

          { projects: projects.map do |project|
            shape(project, briefs.fetch(project.id, []), open.fetch(project.id, 0), pauses[project.id])
          end }
        end
      end

      def pause_actors(workspace_id, ids)
        Event.where(workspace_id: workspace_id, project_id: ids, type: "project.paused").order(:seq)
          .pluck(:project_id, :actor_kind).to_h
      end

      def shape(project, brief, open_tasks, pause_actor)
        { id: project.id, name: project.name.to_s, goal: project.goal.to_s,
          budget: Shapes.number(project.budget), spent: Shapes.number(project.spent), paused: project.paused,
          brief_version: project.brief_version, brief: brief.map { |entry| brief_entry(entry) },
          paused_by: { "owner" => "owner", "app" => "budget" }[pause_actor],
          open_tasks: open_tasks, content_deleted_at: Shapes.time(project.content_deleted_at) }
      end

      def brief_entry(entry)
        { id: entry.id, project_id: entry.project_id, kind: entry.kind, text: entry.text.to_s,
          author_kind: entry.author_kind, author_id: entry.author_id }
      end
    end
  end
end
