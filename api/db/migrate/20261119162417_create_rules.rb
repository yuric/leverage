# Rules and their immutable versions (PRD, Data model and The rule record;
# plan DB-28, DB-29). `enabled` lives on rules only (P-4).
class CreateRules < ActiveRecord::Migration[8.1]
  def change
    create_table :rules, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true, index: false
      t.text :key, null: false
      t.boolean :enabled, null: false
      t.integer :current_version, null: false
      t.timestamptz :removed_at
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamptz :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :workspace_id, :key ], unique: true
    end

    create_table :rule_versions, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :rule, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :version, null: false
      t.text :key, null: false
      t.text :name, null: false
      t.text :hook, null: false
      t.text :scope_kind, null: false
      t.jsonb :scope_values, null: false, default: []
      t.text :kind, null: false
      t.text :checker, null: false
      t.text :checker_function
      t.jsonb :parameters
      t.text :instruction
      t.text :checker_role
      t.text :on_fail
      t.text :route
      # Null means the workspace's default.
      t.integer :queue_timeout_seconds
      t.integer :run_timeout_seconds
      t.text :origin, null: false
      t.text :author_kind, null: false
      t.uuid :author_id
      t.timestamptz :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.index [ :rule_id, :version ], unique: true
      # What rule_checks' composite foreign key references.
      t.index [ :rule_id, :id ], unique: true
    end

    # A rule's current version is a version of that rule. Deferred, because
    # a rule and its first version are written in one transaction.
    add_foreign_key :rules, :rule_versions, column: [ :id, :current_version ], primary_key: [ :rule_id, :version ],
      deferrable: :deferred, name: "rules_current_version_fkey"
  end
end
