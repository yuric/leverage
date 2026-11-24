module Leverage
  module Rules
    module Checkers
      # Routes a new question using the seats connected to its workspace.
      module RouteQuestion
        module_function

        def call(version:, request:, task:)
          dedicated = Seat.exists?(workspace_id: request.workspace_id, role: "orchestrator", enabled: true, removed_at: nil)
          connected = dedicated || reachable_general?(request, task)
          AppCheckers::Result.new(result: "applied", reason: nil, effect: connected ? "to_orchestrator" : "to_owner")
        end

        def reachable_general?(request, task)
          question = ::Question.find_by(workspace_id: request.workspace_id, id: request.subject_id)
          return false unless question && task

          at = question.asked_at
          job = Job.new(workspace_id: request.workspace_id, task_id: task.id, project_id: task.project_id,
            target_kind: "question", target_id: question.id, seat_role: "orchestrator", kind: "question",
            state: "queued", queued_at: at, attempt_number: 1)
          RolePresence.online_seats(request.workspace_id, "orchestrator", at).any? do |seat|
            seat.id != question.asking_seat_id &&
              Jobs.next_for(seat, at: at, additional: [ job ]).equal?(job)
          end
        end

        private_class_method :reachable_general?
      end
    end
  end
end
