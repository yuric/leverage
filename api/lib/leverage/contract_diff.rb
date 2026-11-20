module Leverage
  # Compares a task's criteria with an edited contract (PRD Contract edits
  # and cancel, L205; milestone 3 plan HE-25 (i)). Not built yet: the red
  # tests of WP6 run against it.
  module ContractDiff
    Diff = Data.define(:kept, :reset, :added, :removed)
    Written = Data.define(:added_ids, :reset_ids, :removed_ids)

    module_function

    def compare(_current, _wanted) = Diff.new(kept: [], reset: [], added: [], removed: [])

    def write(_task, _wanted, at:) = Written.new(added_ids: [], reset_ids: [], removed_ids: [])
  end
end
