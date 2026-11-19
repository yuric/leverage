module Leverage
  module Transitions
    module Entries
      # The command_key_retention timer (PRD L220, L818; timers.json;
      # milestone 2 plan EN-22): a workspace timer, fired only by the sweep.
      # It purges the workspace's commands rows older than RETENTION, the
      # least time an idempotency key is kept, and its sweep_runs rows
      # older than the same, at most params limit (default BATCH) of each
      # per run. It writes no event. A key it purged is new again.
      #
      # Result: commands_deleted, sweep_runs_deleted, and more (whether a
      # full batch of either went, so the sweep runs it again).
      class CommandKeyRetention < Entry
        RETENTION = 7.days
        BATCH = 1000

        def refusals(_ctx) = [ state_refusal(nil) ].compact

        def perform(ctx)
          limit = Integer(ctx.request.params.fetch("limit", BATCH))
          cutoff = ctx.at - RETENTION
          workspace_id = ctx.workspace.id
          commands = purge(Command.where(workspace_id: workspace_id).where(created_at: ...cutoff), limit)
          runs = purge(SweepRun.where(workspace_id: workspace_id).where(ran_at: ...cutoff), limit)
          @result = { "commands_deleted" => commands, "sweep_runs_deleted" => runs,
                      "more" => commands == limit || runs == limit }
        end

        private

        def purge(scope, limit)
          ids = scope.order(:id).limit(limit).pluck(:id)
          ids.empty? ? 0 : scope.klass.where(id: ids).delete_all
        end
      end
    end
  end
end
