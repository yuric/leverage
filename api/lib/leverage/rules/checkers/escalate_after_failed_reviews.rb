module Leverage
  module Rules
    module Checkers
      # Plans escalation only when a stronger builder seat can take the rework.
      module EscalateAfterFailedReviews
        module_function

        def call(version:, request:, task:)
          threshold = version.parameters.fetch("threshold")
          escalates = task && failed_count(task, request) >= threshold && stronger_builder?(task)
          AppCheckers::Result.new(result: "applied", reason: nil, effect: ("escalated" if escalates))
        end

        def failed_count(task, request)
          count = ReviewRounds.failed_count(task)
          # The failing verdict may still be in the command's request.
          incoming = Review.exists?(workspace_id: task.workspace_id, task_id: task.id, id: request.subject_id, verdict: nil)
          count + (incoming ? 1 : 0)
        end

        def stronger_builder?(task)
          return false unless task.builder_seat_id

          rank = Seat.where(workspace_id: task.workspace_id, id: task.builder_seat_id).pick(:strength_rank)
          return false unless rank

          Seat.where(workspace_id: task.workspace_id, role: Roles.roles_acting_as("builder"), enabled: true, removed_at: nil)
            .where("strength_rank > ?", rank).any? { |seat| Eligibility.standing?(seat, task, rank: rank + 1) }
        end

        private_class_method :failed_count, :stronger_builder?
      end
    end
  end
end
