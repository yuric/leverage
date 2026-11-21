# One usage reading of a credential (milestone 6).
# An Active Record class with no callbacks (milestone 2 plan §2.1).
class CredentialReading < ApplicationRecord
  scope :newest_for, ->(credential) {
    where(workspace_id: credential.workspace_id, credential_id: credential.id)
      .order(observed_at: :desc, created_at: :desc, id: :desc)
  }
end
