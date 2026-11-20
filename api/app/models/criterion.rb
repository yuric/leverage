# One acceptance criterion of a task's contract.
# An Active Record class with no callbacks and no logic (milestone 2 plan §2.1).
class Criterion < ApplicationRecord
  self.table_name = "criteria"
end
