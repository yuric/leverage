module Leverage
  # The repair of the steps stored for a promoted Imaginarium idea (FR-039;
  # PRD, Steps and timing, and "What the replay test rebuilds").
  #
  # Until the step tracker read the criteria task.created lists
  # (Steps.criteria_as_of), it saw such a task as one with no criteria: the
  # acknowledged briefing opened finish instead of build, and no build or
  # review step named a criterion. The log was right and the rows were not.
  # The replay rebuilds steps with today's tracker, so those rows fail the
  # replay test (leverage:verify_log), and a restore refuses a dump that
  # holds them.
  #
  # The repair rebuilds, from the log, the steps of every task whose
  # task.created lists criteria, and of no other task: the tracker read
  # every other task's criteria the same way before. A task whose rows
  # already are the log's keeps them, ids included, so a second run changes
  # nothing. It writes no event: steps are derived rows.
  #
  # It runs once per database, in the migration MIGRATION names, and in a
  # restore of a dump made before that migration (Backup.restore_into),
  # before the replay test.
  module StepRepair
    # The version of db/migrate's RebuildStepsOfPromotedIdeas.
    MIGRATION = "20261125190000".freeze

    module_function

    # Repairs every such task of every workspace. Returns the ids of the
    # tasks whose rows it rewrote.
    def call
      tasks_with_listed_criteria.select { |workspace_id, task_id| rebuild(workspace_id, task_id) }.map(&:last)
    end

    # Whether the database has had the repair: its migration is recorded.
    def migrated?(connection = ActiveRecord::Base.lease_connection)
      connection.select_value(
        "SELECT 1 FROM schema_migrations WHERE version = #{connection.quote(MIGRATION)}"
      ).present?
    end

    def tasks_with_listed_criteria
      Event.where(type: "task.created").where.not(task_id: nil)
        .where("jsonb_array_length(coalesce(payload->'added_criterion_ids', '[]'::jsonb)) > 0")
        .order(:workspace_id, :seq).pluck(:workspace_id, :task_id)
    end

    # Drives the tracker over the task's events again, as the replay does
    # over a workspace's, and keeps the result only when it differs from the
    # rows stored. Returns whether it did.
    def rebuild(workspace_id, task_id)
      changed = false
      ActiveRecord::Base.transaction(requires_new: true) do
        stored = rows(task_id)
        TaskStep.where(workspace_id: workspace_id, task_id: task_id).delete_all
        Event.where(workspace_id: workspace_id, task_id: task_id).order(:seq).each { |event| Steps.on_event(nil, event) }
        changed = rows(task_id) != stored
        raise ActiveRecord::Rollback unless changed
      end
      changed
    end

    def rows(task_id)
      TaskStep.where(task_id: task_id).pluck(*Replay::STEP_COLUMNS).sort_by { |row| row.map(&:to_s) }
    end
  end
end
