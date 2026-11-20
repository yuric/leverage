module Leverage
  module Transitions
    module Entries
      # The builder_lease_expiry timer (PRD L119-L123; timers.json;
      # state_machine.json): a builder's lease that has reached its due time
      # ends. From Working the task goes back to Ready with no holder and no
      # builder (PRD, What the replay test rebuilds: the builder is cleared
      # when the task returns to Ready; L121's "keeps its builder seat" is
      # about In review), and keeps every criterion that passed (L123). task.lease_expired is written by the app, with no
      # command_id, at the due time (Timers.effective_at).
      #
      # It runs in two ways, through the same code (L118):
      #
      #   inside another command  Timers.apply_due makes it with targets:,
      #                           the one task that command touches;
      #   as its own command      the sweep's, by the app: params task_id
      #                           names one task, or with none it takes the
      #                           workspace's due tasks, oldest due first,
      #                           at most params limit (default BATCH).
      #
      # Result: expired_task_ids, the tasks whose lease it ended.
      #
      # A seat-bound hold (seat_paused, credential_limit: their lease clock
      # runs) closes after task.lease_expired, at the same due time, by the
      # app (Holds.close_seat_bound, SM-15). The wait_ready step that opens
      # has the cause of HE-35 (Candidates.wait_cause, asked at the due time
      # once the seat holds nothing): on task.lease_expired when the task
      # had no hold, else on the hold.closed that leaves it with none
      # (milestone 3 plan §2.1, changed entries; trace 14).
      #
      # A pending submit is cancelled first, with lease_expired (L376;
      # milestone 4 plan §2.1 rule 11): its withdrawals are the timer's, at
      # the due time, by the app, with no key (trace 18, command 36), also
      # when the timer runs inside another command. No Finishing task exists
      # before milestone 5: Finishing has its row and no way to reach it.
      class BuilderLeaseExpiry < Entry
        BATCH = 100

        def initialize(command = self.class.command, targets: nil)
          super(command)
          @tasks = targets
          @named = !targets.nil?
        end

        def load(ctx)
          return if @tasks

          params = ctx.request.params
          if params.key?("task_id")
            @named = true
            @tasks = [ Task.find_by(id: params["task_id"], workspace_id: ctx.workspace.id) ||
                         raise(NotFound, "no such task") ]
          else
            limit = Integer(params.fetch("limit", BATCH))
            @tasks = Timers.due_tasks(ctx.workspace.id, ctx.at, from_states, limit: limit)
          end
        end

        # A named task must be in a state the timer has a row for.
        def refusals(_ctx)
          return [] unless @named

          [ state_refusal(@tasks.sole.state) ].compact
        end

        def perform(ctx)
          expired = @tasks.select { |task| Leases.due?(task, ctx.at) }
          expired.each { |task| expire(ctx, task) }
          @result = { "expired_task_ids" => expired.map(&:id) }
        end

        private

        def expire(ctx, task)
          row = state_row(task.state)
          effective_at = Timers.effective_at(task, task.lease_due_at)
          pending = PendingTransitions.of(task)
          if pending
            PendingTransitions.cancel(ctx, pending, "lease_expired", effective_at: effective_at, actor_kind: "app",
              actor_id: nil, command_id: nil)
          end
          held = Holds.held?(task)
          Leases.end_lease(ctx, task)
          to = row.fetch("to") || task.state
          builder = to == "ready" ? { builder_seat_id: nil } : {}
          task.update!(state: to, holder_seat_id: nil, resume_pending_since: nil, **builder)
          wait_cause = Candidates.wait_cause(task, effective_at) if to == "ready"
          expired = ctx.emit("task.lease_expired", task: task, payload: { wait_cause: (wait_cause unless held) },
            actor_kind: "app", actor_id: nil, command_id: nil, effective_at: effective_at)
          Holds.close_seat_bound(ctx, task, cause: expired, wait_cause: wait_cause)
        end

        def from_states = rows.map { |row| row.fetch("from") }
      end
    end
  end
end
