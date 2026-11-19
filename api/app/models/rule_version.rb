# One version of a rule (milestone 4). The table is append-only, like
# events: the database refuses an update or a delete.
# An Active Record class with no callbacks and no logic (milestone 2 plan §2.1).
class RuleVersion < ApplicationRecord
  def readonly? = persisted? || super
end
