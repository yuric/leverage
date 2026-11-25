# The steps of a promoted Imaginarium idea were stored wrongly until the
# step tracker read the criteria task.created lists (FR-039): the rows no
# longer match the ones the replay rebuilds from the log, so
# leverage:verify_log fails and a restore refuses the dump. This rebuilds
# those tasks' steps from the log, once (Leverage::StepRepair). It changes
# no table's shape and writes no event; a database with no such task is
# left as it is. A restore of a dump made before this migration runs the
# same repair before its replay test (Leverage::Backup).
class RebuildStepsOfPromotedIdeas < ActiveRecord::Migration[8.1]
  def up
    repaired = Leverage::StepRepair.call
    say "rebuilt the steps of #{repaired.size} promoted Imaginarium ideas"
  end

  # The rows before the repair were not the log's; there is nothing to go
  # back to.
  def down; end
end
