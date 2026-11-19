module Leverage
  module Transitions
    module Entries
      # allow_another_round (PRD L163, L191; milestone 2 plan EN-31, DB-15):
      # with an open rounds_exceeded hold, the owner adds one to the task's
      # extra_rounds and closes the hold (Holds.close: hold.closed with no
      # fresh lease, inbox.resolved with the choice allow_another_round,
      # the lease clock restarted and resume pending when no hold is left).
      # The next failure at the new limit opens the hold again. Other open
      # holds stay open. Without that hold it is invalid_state.
      #
      # Params: id (the task).
      class AllowAnotherRound < Entry
        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          @hold = Holds.open_holds(@task).find { |hold| hold.reason == "rounds_exceeded" }
        end

        def refusals(_ctx)
          return [ Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) ] unless @hold

          [ state_refusal(nil) ].compact
        end

        def perform(ctx)
          @task.update!(extra_rounds: @task.extra_rounds + 1)
          Holds.close(ctx, hold: @hold, task: @task, choice: "allow_another_round")
          @result = nil
        end
      end
    end
  end
end
