module Leverage
  module Transitions
    module Entries
      # hold (PRD Lifecycle L104, Holds L168, L176; milestone 3 plan HE-24,
      # HS-3): the owner holds a task with owner_hold, in any state but
      # Finishing, Done and Cancelled. hold.opened is the owner's; the
      # reason has no Needs you item and pauses the lease clocks (Holds).
      # From Ready, a provisional claim's reservation lapses: Holds.open
      # cancels the pending claim with invalid_state before hold.opened
      # (milestone 4 plan RD-13, rule 11). A pending transition in any other
      # state keeps waiting under the hold (L378).
      # The row from Finishing is not served until milestone 5 brings that
      # state: invalid_state. A task the owner already holds is
      # invalid_state too: one owner_hold at a time, which Resume closes.
      # Inside Entries this class is Hold: the model is ::Hold.
      #
      # Params: id (the task).
      class Hold < Entry
        REASON = "owner_hold".freeze

        # The state whose row is not served in this milestone (HS-3).
        NOT_SERVED_FROM = %w[finishing].freeze

        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx)
          return [ invalid_state ] if NOT_SERVED_FROM.include?(@task.state)

          causes = [ state_refusal(@task.state) ]
          causes << invalid_state if Holds.open_holds(@task).any? { |hold| hold.reason == REASON }
          causes.compact
        end

        def perform(ctx)
          kind, id = ctx.actor
          Holds.open(ctx, task: @task, reason: REASON, actor_kind: kind, actor_id: id)
          @result = nil
        end

        private

        def invalid_state = Refusal.new(code: Contract.state_machine.fetch("unlisted_pair_refusal"))
      end
    end
  end
end
