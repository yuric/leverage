# DB-53: a workspace knows its Imaginarium project by id, not by name. The
# column is empty until create_owner, or install_imaginarium_project for a
# workspace made before this, creates the project.
class AddWorkspaceImaginariumProject < ActiveRecord::Migration[8.1]
  def change
    add_reference :workspaces, :imaginarium_project, type: :uuid, null: true, index: false,
      foreign_key: { to_table: :projects }
  end
end
