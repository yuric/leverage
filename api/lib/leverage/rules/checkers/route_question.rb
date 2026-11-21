module Leverage
  module Rules
    module Checkers
      # Routes a new question using the seats connected to its workspace.
      module RouteQuestion
        module_function

        def call(version:, request:, task:)
          connected = Seat.exists?(workspace_id: request.workspace_id, role: "orchestrator", enabled: true, removed_at: nil)
          AppCheckers::Result.new(result: "applied", reason: nil, effect: connected ? "to_orchestrator" : "to_owner")
        end
      end
    end
  end
end
