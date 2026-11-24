module Leverage
  module Reads
    # The health line (get_system_health; milestone 2 plan IN-33): the
    # sweep's last run and whether it is more than 120 seconds late, when the
    # helper last reported, the queue lengths, and the daily backup's time
    # and whether it is late.
    #
    # The orchestrator's half (milestone 4 plan §2.3, RD-17, RD-18):
    # orchestrator is not_set_up while the workspace has no enabled
    # orchestrator or General seat that is not removed, else online or offline as
    # RolePresence says (L401) at the database's time; waiting_checks is
    # waiting_checks below, which the open "Orchestrator offline" item's
    # count is too (Inbox), so the line and the item never disagree.
    #
    # Whether a role is online is RolePresence's, asked through
    #
    #   presence.online?(workspace, role, at)
    #
    # and with_collaborators puts a double in place for a test.
    module SystemHealth
      LATE_AFTER_SECONDS = 120
      BACKUP_LATE_AFTER_SECONDS = 26 * 3600
      BACKUP_GRACE_SECONDS = 3600

      @collaborators = {}

      class << self
        # Raises ActiveRecord::RecordNotFound for an unknown workspace.
        def call(workspace_id)
          Snapshot.call(workspace_id) do |_as_of_seq|
            last_run = SweepRun.where(workspace_id: workspace_id).maximum(:ran_at)
            { sweep_last_ran_at: Shapes.time(last_run), sweep_late: last_run.nil? || database_now - last_run > LATE_AFTER_SECONDS,
              helper_last_reported_at: Shapes.time(Helper.where(workspace_id: workspace_id).maximum(:last_reported_at)),
              queued_helper_requests: ::HelperRequest.where(workspace_id: workspace_id, state: "queued").count,
              ready_tasks: Task.where(workspace_id: workspace_id, state: "ready").count,
              waiting_reviews: Review.where(workspace_id: workspace_id, verdict: nil, reviewer_seat_id: nil).count,
              orchestrator: orchestrator(workspace_id) }.merge(backup(workspace_id)).merge(waiting_checks: waiting_checks(workspace_id))
          end
        end

        # Tests only: answers RolePresence from presence inside the block.
        def with_collaborators(presence: nil)
          saved = @collaborators
          @collaborators = saved.merge({ presence: presence }.compact)
          yield
        ensure
          @collaborators = saved
        end

        # "N checks waiting" (RD-18): the rule checks whose job is queued and
        # not claimed, and those held with check_error, each once (a check
        # queued again while its hold is still open is one check), counted
        # each time it is read.
        def waiting_checks(workspace_id)
          queued = Job.where(workspace_id: workspace_id, target_kind: "rule_check", state: "queued").select(:target_id)
          held = Hold.where(workspace_id: workspace_id, reason: "check_error", closed_at: nil)
            .select(Arel.sql("COALESCE(rule_check_id, id)"))
          ActiveRecord::Base.lease_connection.select_value(
            "SELECT count(*) FROM (#{queued.to_sql} UNION #{held.to_sql}) AS waiting"
          ).to_i
        end

        # not_set_up, online or offline (RD-17).
        def orchestrator(workspace_id)
          return "not_set_up" unless RolePresence.configured?(workspace_id, "orchestrator")

          presence.online?(Workspace.find(workspace_id), "orchestrator", database_now) ? "online" : "offline"
        end

        # The newest dump's time and whether it is late (milestone 3 plan
        # HB-4). A dump is of the whole database, so backup_runs has no
        # workspace: the newest row is this workspace's too. It is late when
        # the newest is older than 26 hours, or when there is none and the
        # workspace is older than one hour (the first dump follows the
        # owner's sign-up within a minute).
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

        private

        def presence = @collaborators[:presence] || RolePresence
      end
    end
  end
end
