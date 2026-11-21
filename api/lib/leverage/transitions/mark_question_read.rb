module Leverage
  module Transitions
    # The read clears the asking seat's answer notice (DB-35). The
    # controller passes its authorized question. Recheck that the seat
    # still holds the task and the delivered answer is still current.
    module MarkQuestionRead
      module_function

      def call(question, seat: nil)
        return false if seat && (seat.id != question.asking_seat_id || seat.workspace_id != question.workspace_id)
        return false unless %w[answered overturned].include?(question.outcome) && question.read_at.nil?

        ActiveRecord::Base.transaction(requires_new: true) do
          _workspace, at = WorkspaceLock.take(question.workspace_id)
          task = Task.find_by(id: question.task_id, workspace_id: question.workspace_id)
          next false unless task&.holder_seat_id == question.asking_seat_id && Leases.live?(task, at)

          Question.where(id: question.id, workspace_id: question.workspace_id, asking_seat_id: question.asking_seat_id,
            outcome: question.outcome, answered_at: question.answered_at, read_at: nil).update_all(read_at: at) == 1
        end
      end
    end
  end
end
