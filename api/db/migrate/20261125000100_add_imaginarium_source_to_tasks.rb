class AddImaginariumSourceToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :imaginarium_entry_id, :string, limit: 128
    add_column :tasks, :imaginarium_catalog_version, :integer
    add_check_constraint :tasks, <<~SQL.squish, name: "tasks_imaginarium_source"
      (imaginarium_entry_id IS NULL AND imaginarium_catalog_version IS NULL) OR
      (imaginarium_entry_id IS NOT NULL AND imaginarium_catalog_version IS NOT NULL AND imaginarium_catalog_version > 0)
    SQL
  end
end
