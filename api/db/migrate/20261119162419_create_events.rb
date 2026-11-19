# The event log (PRD, Event log, "The event record"). Append-only: the
# triggers come in their own migration. No foreign key on actor or subject,
# whose kinds vary; the registry's lists are the authority for type, actor
# and subject kinds (DB-8, DB-9, DB-47).
class CreateEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :events, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true, index: false
      t.bigint :seq, null: false
      t.timestamptz :at, null: false
      t.timestamptz :effective_at, null: false
      t.text :type, null: false
      t.integer :schema_version, null: false
      t.text :actor_kind, null: false
      t.uuid :actor_id
      t.references :project, type: :uuid, foreign_key: true
      t.references :task, type: :uuid, foreign_key: true
      t.integer :round
      t.text :subject_kind
      t.uuid :subject_id
      t.references :cause, type: :uuid, foreign_key: { to_table: :events }
      # Indexed, not unique: every event of one command shares it (C3).
      t.text :command_id, index: true
      t.jsonb :payload, null: false
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      # The top-level transaction that wrote the row, inside savepoints too.
      # The state trigger reads it (C7); it is not part of the event record.
      t.column :xact_id, :xid8, null: false, default: -> { "pg_current_xact_id()" }

      t.index [ :workspace_id, :seq ], unique: true
      t.index [ :workspace_id, :task_id, :seq ]
      t.index [ :task_id, :xact_id ]
      t.check_constraint "(task_id IS NULL) = (round IS NULL)", name: "events_round_with_task"
      t.check_constraint "(subject_kind IS NULL) = (subject_id IS NULL)", name: "events_subject_pair"
    end
  end
end
