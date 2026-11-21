# The Questions and approvals milestone's schema changes (plan section 2.3).
class AddQuestionsAndApprovalsColumns < ActiveRecord::Migration[8.1]
  def up
    add_column :brief_entries, :position, :integer
    # Preserve the order the previous brief reader used for existing rows.
    execute <<~SQL
      UPDATE brief_entries
      SET position = ordered.position
      FROM (
        SELECT id, row_number() OVER (PARTITION BY project_id ORDER BY created_at, id) AS position
        FROM brief_entries
      ) AS ordered
      WHERE brief_entries.id = ordered.id
    SQL
    change_column_null :brief_entries, :position, false
    add_index :brief_entries, %i[project_id position], unique: true

    # These values are the registry lists as of this migration. A later
    # change to a list needs its own migration.
    add_check_constraint :questions, "outcome IN ('open', 'answered', 'passed_on', 'overturned')",
      name: "questions_outcome_known"
    add_check_constraint :questions, "basis IN ('record', 'decision', 'owner')",
      name: "questions_basis_known"
    change_column_null :jobs, :input, true
    add_index :tasks, :workspace_id, where: "state = 'finishing' AND holder_seat_id IS NULL",
      name: "index_tasks_waiting_for_finishing_lease"
  end
end
