module Leverage
  # The references that stop Remove, and those it clears before deleting
  # a credential (PRD, Credentials, CR-32). The caller holds the workspace lock.
  module CredentialUse
    module_function

    def in_use?(credential)
      named = { workspace_id: credential.workspace_id, credential_id: credential.id }
      seats = Seat.where(workspace_id: credential.workspace_id, removed_at: nil)
      seats.where(credential_id: credential.id).or(seats.where(run_credential_id: credential.id)).exists? ||
        Task.where(named).where.not(state: %w[done cancelled]).exists? ||
        Review.exists?(**named, verdict: nil) ||
        Job.exists?(**named, state: %w[queued claimed]) ||
        Hold.exists?(**named, closed_at: nil) ||
        InboxItem.exists?(**named, state: "open")
    end

    def release(ctx, credential)
      removed = Seat.where(workspace_id: ctx.workspace.id).where.not(removed_at: nil)
      removed.where(credential_id: credential.id).update_all(credential_id: nil, updated_at: ctx.at)
      removed.where(run_credential_id: credential.id).update_all(run_credential_id: nil, updated_at: ctx.at)
      HelperRequest.where(workspace_id: ctx.workspace.id, credential_id: credential.id, state: SeatRuns::UNFINISHED)
        .where.not(kind: "stop_seat").update_all(state: "failed", result: nil, finished_at: ctx.at, updated_at: ctx.at)
    end
  end
end
