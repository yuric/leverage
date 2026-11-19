# Tasks and what their contracts hold: criteria, evidence, review rounds,
# questions and outward actions (PRD, Data model; plan DB-10 to DB-22).
# Content columns are nullable: deleting content blanks them (DB-42).
class CreateTasksAndContracts < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, foreign_key: true
      t.text :title
      t.text :goal
      t.text :details
      t.text :work_reference
      t.text :state, null: false
      t.integer :round, null: false, default: 0
      # At most one task per holder (C18).
      t.references :holder_seat, type: :uuid, foreign_key: { to_table: :seats },
        index: { unique: true, where: "holder_seat_id IS NOT NULL" }
      t.references :builder_seat, type: :uuid, foreign_key: { to_table: :seats }
      t.timestamptz :lease_due_at
      t.interval :lease_time_left_while_paused
      t.integer :minimum_strength_rank
      t.integer :contract_version, null: false, default: 0
      t.decimal :budget_cap, precision: 14, scale: 6
      t.decimal :spent, precision: 14, scale: 6, null: false, default: 0
      t.text :priority, null: false, default: "normal"
      t.integer :extra_rounds, null: false, default: 0
      # The credential last recorded for the task; no foreign key (DB-10).
      t.uuid :credential_id
      t.timestamptz :resume_pending_since
      t.timestamptz :content_deleted_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    create_table :criteria, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, null: false, foreign_key: true
      t.integer :position, null: false
      t.text :text
      t.text :kind, null: false
      t.text :state, null: false, default: "open"
      t.timestamptz :passed_at
      t.references :passed_by_seat, type: :uuid, foreign_key: { to_table: :seats }
      # A removed criterion keeps its row for the evidence and steps that name it.
      t.timestamptz :removed_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :task_id, :position ], unique: true, where: "removed_at IS NULL",
        name: "index_criteria_on_task_id_and_position_not_removed"
    end

    create_table :evidence, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :criterion, type: :uuid, null: false, foreign_key: { to_table: :criteria }
      t.text :kind, null: false
      t.text :value
      t.references :attached_by_seat, type: :uuid, null: false, foreign_key: { to_table: :seats }
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # One row per round, created at submit with no reviewer (DB-20).
    create_table :reviews, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :round, null: false
      # At most one live review per reviewer (C18, PRD L122): a review with a
      # verdict keeps its reviewer (DB-20), so only reviews with no verdict
      # count.
      t.references :reviewer_seat, type: :uuid, foreign_key: { to_table: :seats },
        index: { unique: true, where: "reviewer_seat_id IS NOT NULL AND verdict IS NULL" }
      t.timestamptz :lease_due_at
      t.interval :lease_time_left_while_paused
      t.text :verdict
      t.uuid :failed_criteria, array: true
      # Its foreign key is added with rule_checks.
      t.uuid :failed_rule_check_id, index: true
      t.text :notes
      t.text :handoff_note
      t.uuid :credential_id
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :task_id, :round ], unique: true
    end

    create_table :questions, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, null: false, foreign_key: true
      t.references :asking_seat, type: :uuid, null: false, foreign_key: { to_table: :seats }
      t.text :text
      t.text :assumption
      t.boolean :blocking, null: false
      t.text :outcome, null: false, default: "open"
      t.text :answer
      t.text :basis
      t.text :answered_by_kind
      t.uuid :answered_by_id
      t.timestamptz :asked_at, null: false
      t.timestamptz :answered_at
      t.timestamptz :read_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    create_table :actions, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :task, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.text :kind, null: false
      t.text :description
      t.text :state, null: false, default: "contracted"
      t.text :approved_by_kind
      t.uuid :approved_by_id
      # Its foreign key is added with jobs.
      t.uuid :approval_job_id, index: true
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :task_id, :position ], unique: true
    end
  end
end
