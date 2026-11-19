# Projects and their briefs (PRD, Data model: projects, brief_entries).
# Content columns are nullable: deleting content blanks them (DB-42).
class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.text :name
      t.text :goal
      t.decimal :budget, precision: 14, scale: 6
      t.decimal :spent, precision: 14, scale: 6, null: false, default: 0
      t.boolean :paused, null: false, default: false
      t.integer :brief_version, null: false, default: 0
      t.timestamptz :content_deleted_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    create_table :brief_entries, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.text :kind, null: false
      t.text :text
      t.text :author_kind, null: false
      t.uuid :author_id
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
