# Holds, Needs you items, task steps and briefing acknowledgements (PRD,
# Holds, Steps and timing, The briefing, Data model; plan DB-11, DB-23,
# DB-32, DB-33).
class CreateHoldsInboxStepsAndAcknowledgements < ActiveRecord::Migration[8.1]
  def change
    # One row per task, project_paused included (DB-23).
    create_table :holds, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, foreign_key: true
      t.text :reason, null: false
      t.references :rule, type: :uuid, foreign_key: true
      t.references :rule_check, type: :uuid, foreign_key: true
      t.references :action, type: :uuid, foreign_key: true
      t.uuid :credential_id
      t.text :detail
      t.timestamptz :opened_at, null: false
      t.timestamptz :closed_at
      t.text :opened_by_kind, null: false
      t.uuid :opened_by_id
      t.text :closed_by_kind
      t.uuid :closed_by_id
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index :task_id, where: "closed_at IS NULL", name: "index_holds_open_on_task_id"
    end

    create_table :inbox_items, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.text :kind, null: false
      t.text :about_kind, null: false
      t.uuid :about_id
      t.references :hold, type: :uuid, foreign_key: true
      t.uuid :credential_id
      # Written when the item opens: the choices it offers and what it names.
      t.jsonb :choices, null: false
      t.jsonb :facts, null: false
      t.text :state, null: false, default: "open"
      t.timestamptz :opened_at, null: false
      t.text :resolved_by_kind
      t.uuid :resolved_by_id
      t.timestamptz :resolved_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index :workspace_id, unique: true, where: "kind = 'orchestrator_offline' AND state = 'open'",
        name: "index_inbox_items_one_open_orchestrator_offline"
      t.index :about_id, unique: true, where: "kind = 'no_reviewer_eligible' AND state = 'open'",
        name: "index_inbox_items_one_open_no_reviewer_eligible"
      t.index :hold_id, unique: true, where: "state = 'open'", name: "index_inbox_items_one_open_per_hold"
    end

    # `step_class` is the PRD's "class": Active Record refuses an attribute
    # named `class`.
    create_table :task_steps, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, null: false, foreign_key: true
      t.integer :round, null: false
      t.text :kind, null: false
      t.text :step_class, null: false
      t.text :subject_kind
      t.uuid :subject_id
      t.references :seat, type: :uuid, foreign_key: true
      t.text :cause_kind
      t.references :cause_rule, type: :uuid, foreign_key: { to_table: :rules }
      t.timestamptz :opened_at, null: false
      t.timestamptz :closed_at
      t.references :opening_event, type: :uuid, null: false, foreign_key: { to_table: :events }
      t.references :closing_event, type: :uuid, foreign_key: { to_table: :events }
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # At most one open step per task (C5); no negative duration (C16).
      t.index :task_id, unique: true, where: "closed_at IS NULL", name: "index_task_steps_one_open_per_task"
      t.check_constraint "closed_at IS NULL OR closed_at >= opened_at", name: "task_steps_no_negative_duration"
    end

    # Kept per seat, per lease and per hash; a lease is named by the event
    # that granted it (DB-11). `briefing_hash`, not `hash`, which Active
    # Record defines.
    create_table :briefing_acknowledgements, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :seat, type: :uuid, null: false, foreign_key: true, index: false
      t.references :task, type: :uuid, null: false, foreign_key: true
      t.references :review, type: :uuid, foreign_key: true
      t.references :lease_event, type: :uuid, null: false, foreign_key: { to_table: :events }
      t.text :briefing_hash, null: false
      t.timestamptz :acknowledged_at, null: false
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :seat_id, :lease_event_id, :briefing_hash ], unique: true,
        name: "index_briefing_acknowledgements_once_per_lease_and_hash"
    end
  end
end
