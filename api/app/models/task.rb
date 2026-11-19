# A task (PRD, Lifecycle). Its state changes only with an event of the task in
# the same transaction (the deferred state trigger).
# An Active Record class with no callbacks and no logic (milestone 2 plan §2.1).
class Task < ApplicationRecord
end
