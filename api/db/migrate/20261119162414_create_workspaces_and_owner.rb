# The workspace, its owner's sign-in and the owner's sessions (PRD, Data
# model: workspaces, users; sessions per plan DB-40).
class CreateWorkspacesAndOwner < ActiveRecord::Migration[8.1]
  def change
    # The workspace row is also the lock every writing transaction takes
    # first, and last_seq is the counter events take their seq from (DB-4).
    # Durations are whole seconds.
    create_table :workspaces, id: :uuid do |t|
      t.integer :lease_length_seconds, null: false, default: 3600
      t.integer :check_queue_timeout_seconds, null: false, default: 120
      t.integer :check_run_timeout_seconds, null: false, default: 300
      t.integer :maximum_rounds, null: false, default: 3
      t.integer :rerun_limit, null: false, default: 3
      t.integer :recovery_time_ceiling_seconds
      t.bigint :last_seq, null: false, default: 0
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    create_table :users, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.text :email_address, null: false, index: { unique: true }
      t.text :password_digest, null: false
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    create_table :sessions, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.text :token_hash, null: false, index: { unique: true }
      t.timestamptz :last_used_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
