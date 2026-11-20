module Leverage
  module Transitions
    # The write behind a poll (PRD L217; milestone 2 plan EN-20, IN-10): a
    # seat's last polled time at most every 10 seconds, the helper's last
    # report every 15, an owner session's last use every 5 minutes. It is
    # not a command and writes no event; like every writer it takes the
    # workspace lock, and it takes it only when the write is due, so a poll
    # that is not due costs one SELECT and holds nothing.
    #
    #   Leverage::Transitions::RecordPoll.seat(seat)        # true when written
    module RecordPoll
      SEAT_SECONDS = 10
      HELPER_SECONDS = 15
      SESSION_SECONDS = 300

      module_function

      def seat(seat) = record(Seat, seat, :last_polled_at, SEAT_SECONDS)
      def helper(helper) = record(::Helper, helper, :last_reported_at, HELPER_SECONDS)
      def session(session) = record(Session, session, :last_used_at, SESSION_SECONDS)

      # Writes the column of the row to the database clock if it is empty or
      # older than seconds. Returns whether it wrote.
      def record(model, row, column, seconds)
        return false unless model.where(id: row.id).where(due(column), seconds).exists?

        ActiveRecord::Base.transaction(requires_new: true) do
          _workspace, at = WorkspaceLock.take(row.workspace_id)
          # Again under the lock: a poll that took it first has written.
          model.where(id: row.id).where("#{column} IS NULL OR #{column} <= ?", at - seconds)
            .update_all(column => at) == 1
        end
      end

      def due(column) = "#{column} IS NULL OR #{column} <= clock_timestamp() - (? * interval '1 second')"
    end
  end
end
