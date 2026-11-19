# Credentials and their readings, the helper and what it is asked to do, and
# seats (PRD, Data model and Credentials; plan DB-36 to DB-39). No secret,
# settings folder or keychain reference is stored; tokens only as hashes.
class CreateCredentialsHelpersAndSeats < ActiveRecord::Migration[8.1]
  def change
    create_table :credentials, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true, index: false
      t.text :kind, null: false
      t.text :provider, null: false
      t.text :name, null: false
      t.text :masked_label
      t.text :plan
      t.text :account_email
      t.text :state, null: false, default: "active"
      t.timestamptz :limited_until
      t.integer :position, null: false
      t.text :model
      t.text :effort
      t.integer :strength_rank
      t.timestamptz :last_verified_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Names are unique within a provider and kind (C19).
      t.index [ :workspace_id, :kind, :provider, :name ], unique: true
      # One helper serves one Mac, and one Mac holds one Gemini login.
      t.index :workspace_id, unique: true, where: "provider = 'gemini' AND kind = 'login'",
        name: "index_credentials_one_gemini_login_per_workspace"
    end
    # Deferred, so that two credentials can swap positions in one transaction.
    add_unique_constraint :credentials, [ :workspace_id, :position ], deferrable: :deferred,
      name: "credentials_position_unique_per_workspace"

    create_table :credential_readings, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :credential, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.timestamptz :observed_at, null: false
      t.text :state, null: false
      t.jsonb :figures, null: false, default: []
      t.jsonb :resets
      t.text :tool_version
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :credential_id, :observed_at ]
    end

    create_table :helpers, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.text :name, null: false
      t.text :token_hash, null: false, index: { unique: true }
      t.timestamptz :last_reported_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    create_table :seats, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.text :name, null: false
      t.text :provider, null: false
      t.text :model, null: false
      t.text :effort, null: false
      t.text :role, null: false
      t.integer :strength_rank, null: false
      # Set for a seat the app runs, empty for a seat that connects on its own.
      t.references :credential, type: :uuid, foreign_key: true
      t.boolean :enabled, null: false, default: true
      t.boolean :paused, null: false, default: false
      # Null once revoked.
      t.text :token_hash, index: { unique: true }
      t.timestamptz :last_polled_at
      t.text :run_state
      t.timestamptz :removed_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    create_table :helper_requests, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.text :kind, null: false
      t.references :seat, type: :uuid, foreign_key: true
      # No foreign key: an add request names the credential before its row exists.
      t.uuid :credential_id
      t.text :state, null: false, default: "queued"
      t.timestamptz :requested_at, null: false
      t.timestamptz :picked_up_at
      t.timestamptz :finished_at
      t.jsonb :result
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # A seat's token is returned once by the pickup and never stored (IF-15).
      t.check_constraint "result IS NULL OR NOT jsonb_path_exists(result, 'lax $.**.token') " \
        "AND NOT jsonb_path_exists(result, 'lax $.**.seat_token')", name: "helper_requests_result_holds_no_token"
    end
  end
end
