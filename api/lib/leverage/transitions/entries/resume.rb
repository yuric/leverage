module Leverage
  module Transitions
    module Entries
      # resume (PRD Lifecycle L104, Holds L176; milestone 3 plan HE-24,
      # HS-3): the owner closes the task's owner_hold (hold.closed, the
      # owner's), and only that hold: every other hold closes through the
      # choice that answers it. Without an owner_hold it is invalid_state
      # (the row's guard not_held_owner_hold). Holds.close runs the lease
      # clocks again when no pausing hold is left, and marks resume pending
      # when no hold is left on a task a seat holds, and gates the task's
      # pending transition again when this was the last hold (L378,
      # milestone 4 plan §2.1 rule 9). The rows from Finishing are not
      # served until milestone 5: invalid_state.
      #
      # Params: id (the task).
      class Resume < Entry
        NOT_SERVED_FROM = Hold::NOT_SERVED_FROM

        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          @hold = Holds.open_holds(@task).find { |hold| hold.reason == Hold::REASON }
        end

        def refusals(_ctx)
          if NOT_SERVED_FROM.include?(@task.state)
            return [ Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal")) ]
          end

          [ state_refusal(@task.state, [ @hold ? "held_owner_hold" : "not_held_owner_hold" ]) ].compact
        end

        def perform(ctx)
          Holds.close(ctx, hold: @hold, task: @task)
          @result = nil
        end
      end
    end
  end
end
