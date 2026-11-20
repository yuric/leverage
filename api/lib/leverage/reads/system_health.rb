module Leverage
  module Reads
    # The health line (get_system_health; milestone 2 plan IN-33): the
    # sweep's last run and whether it is more than 120 seconds late, when the
    # helper last reported, the queue lengths, and the daily backup's time
    # and whether it is late. The orchestrator is a seat of milestone 4, so
    # it is not set up.
    module SystemHealth
      LATE_AFTER_SECONDS = 120
      BACKUP_LATE_AFTER_SECONDS = 26 * 3600
      BACKUP_GRACE_SECONDS = 3600

      module_function

      # Raises ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id)
        Snapshot.call(workspace_id) do |_as_of_seq|
          last_run = SweepRun.where(workspace_id: workspace_id).maximum(:ran_at)
          { sweep_last_ran_at: Shapes.time(last_run), sweep_late: last_run.nil? || database_now - last_run > LATE_AFTER_SECONDS,
            helper_last_reported_at: Shapes.time(Helper.where(workspace_id: workspace_id).maximum(:last_reported_at)),
            queued_helper_requests: ::HelperRequest.where(workspace_id: workspace_id, state: "queued").count,
            ready_tasks: Task.where(workspace_id: workspace_id, state: "ready").count,
            waiting_reviews: Review.where(workspace_id: workspace_id, verdict: nil, reviewer_seat_id: nil).count,
            orchestrator: "not_set_up" }.merge(backup(workspace_id))
        end
      end

      # The newest dump's time and whether it is late (milestone 3 plan
      # HB-4). A dump is of the whole database, so backup_runs has no
      # workspace: the newest row is this workspace's too. It is late when
      # the newest is older than 26 hours, or when there is none and the
      # workspace is older than one hour (the first dump is made within a
      # minute of the first start).
      def backup(workspace_id)
        last = BackupRun.maximum(:ran_at)
        now = database_now
        late = if last
          now - last > BACKUP_LATE_AFTER_SECONDS
        else
          now - Workspace.where(id: workspace_id).pick(:created_at) > BACKUP_GRACE_SECONDS
        end
        { backup_last_ran_at: Shapes.time(last), backup_late: late }
      end

      def database_now = ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
    end
  end
end
