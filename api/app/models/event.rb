# One event of the log (PRD, Event log). Inserted only by
# Leverage::EventLog.append (test/engine/one_writer_test.rb); the database
# refuses an update or a delete for every role. The type column is the
# event's type, not Active Record's single-table inheritance, and xact_id
# is left to its default (pg_current_xact_id()), which the state trigger
# reads, so the class never loads or writes it.
# An Active Record class with no callbacks and no logic (milestone 2 plan §2.1).
class Event < ApplicationRecord
  self.inheritance_column = nil
  self.ignored_columns = [ "xact_id" ]

  # A saved event is never changed (PRD L767).
  def readonly? = persisted? || super
end
