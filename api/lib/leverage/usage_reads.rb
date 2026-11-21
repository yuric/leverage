module Leverage
  # The workspace's usage reads (PRD, Reading usage, CR-10 and CR-22).
  # The caller supplies the command clock and holds the workspace lock
  # while selecting due accounts, queuing requests or purging them.
  module UsageReads
    HELPERS_REPORT_WITHIN = 6 * Transitions::RecordPoll::HELPER_SECONDS
    READ_INTERVAL = 9.minutes
    REQUEST_RETENTION = 7.days
    SWEEP_LIMIT = 50

    module_function

    def helper_alive?(at, workspace_id:)
      Helper.where(workspace_id: workspace_id, last_reported_at: (at - HELPERS_REPORT_WITHIN)..).exists?
    end

    def due(at, workspace_id:)
      return [] unless helper_alive?(at, workspace_id: workspace_id)

      recently_stored = CredentialReading.where(workspace_id: workspace_id, created_at: (at - READ_INTERVAL)..)
        .select(:credential_id)
      underway = unfinished(workspace_id).where.not(credential_id: nil).select(:credential_id)
      Credential.added.where(workspace_id: workspace_id, state: "active").where.not(id: recently_stored)
        .where.not(id: underway).order(:position).limit(SWEEP_LIMIT).to_a
    end

    # Refresh ignores reading age. A request already underway keeps its id
    # even when a caller asks for it again.
    def queue(ctx, credentials)
      accounts = credentials.uniq(&:id)
      requested = unfinished(ctx.workspace.id).where(credential_id: accounts.map(&:id))
        .order(:requested_at, :id).group_by(&:credential_id)
      accounts.map do |credential|
        request = requested[credential.id]&.first || SeatRuns.queue(ctx, "read_usage", credential_id: credential.id,
          params: { "provider" => credential.provider, "credential_kind" => credential.kind })
        request.id
      end
    end

    def purge(at, workspace_id:)
      HelperRequest.where(workspace_id: workspace_id, kind: "read_usage", state: %w[finished failed])
        .where(finished_at: ...at - REQUEST_RETENTION).delete_all
    end

    def unfinished(workspace_id)
      HelperRequest.where(workspace_id: workspace_id, kind: "read_usage", state: SeatRuns::UNFINISHED)
    end
    private_class_method :unfinished
  end
end
