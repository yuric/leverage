# Command outcomes, the one home of idempotency, and the timer sweep's
# record (PRD, Data model; plan DB-34, DB-45).
class CreateCommandsAndSweepRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :commands, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.text :caller_kind, null: false
      t.uuid :caller_id, null: false
      t.text :key, null: false
      t.text :command, null: false
      # Tells a key reused with a different body from a repeat.
      t.text :request_hash, null: false
      t.references :pending_transition, type: :uuid, foreign_key: true
      t.text :outcome, null: false
      t.jsonb :refusal
      t.jsonb :result
      # For the `command` kind of GET /v1/next.
      t.boolean :notify, null: false, default: false
      t.timestamptz :read_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # This index alone enforces idempotency (C4).
      t.index [ :caller_kind, :caller_id, :key ], unique: true
      # A token a command returns once is never stored (IF-15).
      t.check_constraint "result IS NULL OR NOT jsonb_path_exists(result, 'lax $.**.token') " \
        "AND NOT jsonb_path_exists(result, 'lax $.**.seat_token')", name: "commands_result_holds_no_token"
    end

    create_table :sweep_runs, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true, index: false
      t.timestamptz :ran_at, null: false
      t.integer :tasks_touched, null: false
      t.integer :workspace_timers_fired, null: false
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :workspace_id, :ran_at ]
    end
  end
end
