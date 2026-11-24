# App round 1, contract decision UI-1: a task has no goal. Each task's goal
# is folded into its details first, as api/contract/goal_fold.json says,
# so that nothing is lost, and then the column is dropped. No event carries
# a goal, so the log needs nothing. A project keeps its goal (UI-7).
class FoldTaskGoalIntoDetails < ActiveRecord::Migration[8.1]
  # The characters trimmed from both ends of the goal, and the line between
  # it and the details (goal_fold.json's trimmed and separator).
  TRIMMED = " \t\r\n".freeze
  SEPARATOR = "\n\n".freeze

  def up
    trimmed = connection.quote(TRIMMED)
    execute <<~SQL
      UPDATE tasks
      SET details = CASE
        WHEN details IS NULL OR btrim(details, #{trimmed}) = '' THEN btrim(goal, #{trimmed})
        ELSE btrim(goal, #{trimmed}) || #{connection.quote(SEPARATOR)} || details
      END
      WHERE btrim(coalesce(goal, ''), #{trimmed}) <> ''
        AND btrim(coalesce(goal, ''), #{trimmed}) IS DISTINCT FROM btrim(coalesce(title, ''), #{trimmed})
    SQL
    remove_column :tasks, :goal
  end

  # The column comes back empty: the goal stays in the details.
  def down
    add_column :tasks, :goal, :text
  end
end
