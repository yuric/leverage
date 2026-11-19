# Pending transitions, jobs, rule checks and their attempts (PRD, Data
# model, Pending transitions and Check identity; plan DB-24 to DB-31).
class CreateChecksAndJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_transitions, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, null: false, foreign_key: true
      t.text :command_key, null: false
      t.text :command, null: false
      t.text :requester_kind, null: false
      t.uuid :requester_id, null: false
      t.uuid :frozen_rule_version_ids, array: true, null: false, default: []
      t.text :state, null: false, default: "pending"
      t.jsonb :reasons
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # At most one pending transition per task (C17).
      t.index :task_id, unique: true, where: "state = 'pending'",
        name: "index_pending_transitions_one_pending_per_task"
    end

    # One row per attempt; job.requeued is written on the old row (DB-31).
    create_table :jobs, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.text :kind, null: false
      t.references :task, type: :uuid, foreign_key: true
      t.references :project, type: :uuid, foreign_key: true
      t.text :target_kind, null: false
      t.uuid :target_id, null: false
      t.text :seat_role, null: false
      t.references :claimed_by_seat, type: :uuid, foreign_key: { to_table: :seats }
      t.text :state, null: false, default: "queued"
      t.timestamptz :queued_at, null: false
      t.timestamptz :claimed_at
      t.timestamptz :finished_at
      t.jsonb :input, null: false
      t.jsonb :result
      t.bigint :tokens
      t.decimal :spend, precision: 14, scale: 6
      t.uuid :credential_id
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    create_table :rule_checks, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, foreign_key: true, index: false
      t.references :project, type: :uuid, foreign_key: true
      t.references :rule, type: :uuid, null: false, foreign_key: true
      t.references :rule_version, type: :uuid, null: false, foreign_key: true
      t.text :hook, null: false
      t.integer :round
      t.text :subject_kind
      t.uuid :subject_id
      t.text :input_hash, null: false
      # Null while no attempt has finished (DB-25).
      t.text :result
      t.text :effect
      t.text :reason
      t.references :pending_transition, type: :uuid, foreign_key: true
      t.references :overridden_by_user, type: :uuid, foreign_key: { to_table: :users }
      t.timestamptz :overridden_at
      t.text :override_reason
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # A null task or subject is equal to another null here (C6).
      t.index [ :task_id, :rule_version_id, :hook, :round, :subject_kind, :subject_id, :input_hash ],
        unique: true, nulls_not_distinct: true, name: "index_rule_checks_identity"
    end

    create_table :rule_check_attempts, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :rule_check, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :attempt_number, null: false
      t.references :job, type: :uuid, foreign_key: true
      t.references :checker_seat, type: :uuid, foreign_key: { to_table: :seats }
      t.timestamptz :queued_at, null: false
      t.timestamptz :started_at
      t.timestamptz :finished_at
      t.bigint :tokens
      t.decimal :spend, precision: 14, scale: 6
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :rule_check_id, :attempt_number ], unique: true
    end

    add_foreign_key :reviews, :rule_checks, column: :failed_rule_check_id
    add_foreign_key :actions, :jobs, column: :approval_job_id
  end
end
