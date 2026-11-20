module Leverage
  module Reads
    # The health line (get_system_health; milestone 2 plan IN-33): the
    # sweep's last run and whether it is more than 120 seconds late, when the
    # helper last reported, and the queue lengths. The orchestrator is a
    # seat of milestone 4, so it is not set up.
    module SystemHealth
      LATE_AFTER_SECONDS = 120

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
            orchestrator: "not_set_up" }
        end
      end

      def database_now = ActiveRecord::Base.lease_connection.select_value("SELECT clock_timestamp()")
    end
  end
end
