# The Handoff milestone's additions to the Data model (milestone 3 plan,
# section 2.3): when a credential's limit was reported, the credential a
# seat's run is on and why its last run ended, and the record of each daily
# backup. Forward only (PRD, Data model); it touches no event.
class AddHandoffColumns < ActiveRecord::Migration[8.1]
  def change
    # A limit was reported; limited_until says when it ends, if the provider
    # said, and is never set without it (HE-3).
    add_column :credentials, :limited_since, :timestamptz
    add_check_constraint :credentials, "limited_until IS NULL OR limited_since IS NOT NULL",
      name: "credentials_limited_until_needs_limited_since"
    # Add credential sets strength rank 1, the seats' default (HE-5, IN-29);
    # a credential added before this milestone gets it too.
    up_only { execute "UPDATE credentials SET strength_rank = 1 WHERE strength_rank IS NULL" }

    # The credential the seat's current token was issued for, with no
    # foreign key, as tasks.credential_id (DB-10), and why its last run
    # ended: one of the stop reasons of RunStoppedReport (HD-3, HD-10).
    add_column :seats, :run_credential_id, :uuid
    add_column :seats, :run_stop_reason, :text

    # One row per dump, written by the owner role's backup; the application's
    # role may only read it (db:grants). No workspace_id: a dump is of the
    # whole database, and the first is made before any workspace exists
    # (HB-4).
    create_table :backup_runs, id: :uuid do |t|
      t.timestamptz :ran_at, null: false
      t.text :file_name, null: false
      t.bigint :bytes, null: false
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index :file_name, unique: true
      t.index :ran_at
    end
  end
end
