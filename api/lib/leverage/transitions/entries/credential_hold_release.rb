module Leverage
  module Transitions
    module Entries
      # The credential_hold_release timer (PRD L696-L699; timers.json;
      # state_machine.json; milestone 3 plan §2.1 rules 7 and 8, HE-21,
      # HE-23): a task's credential hold (credential_limit or
      # credential_signed_out) is due at the task's last effective time when
      # one of its holder's candidates was available then, else at the
      # earliest reset among its signed-in candidates (Timers, rule 8). At
      # that time it closes and the work goes on on the first candidate
      # available (Handoff.release): hold.closed, credential.switched when
      # that is not the credential recorded for the task, inbox.resolved for
      # an open item, and a start of the seat's run on it. The app writes
      # them, with no command_id, at the due time.
      #
      # It runs in two ways, through the same code (L118):
      #
      #   inside another command  Timers.apply_due makes it with targets:,
      #                           the one task that command touches;
      #   as its own command      the sweep's, by the app: params task_id
      #                           names one task, or with none it takes the
      #                           workspace's due holds, oldest due first,
      #                           at most params limit (default BATCH).
      #
      # Result: released_task_ids, the tasks whose hold it closed.
      class CredentialHoldRelease < Entry
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
            @tasks = Timers.due_credential_holds(ctx.workspace.id, ctx.at, from_states, limit: limit)
          end
        end

        # A named task must be in a state the timer has a row for.
        def refusals(_ctx)
          return [] unless @named

          [ state_refusal(@tasks.sole.state) ].compact
        end

        def perform(ctx)
          released = @tasks.select do |task|
            due = Timers.credential_hold_due_at(task)
            due && due <= ctx.at && Handoff.release(ctx, task, due_at: due).any?
          end
          @result = { "released_task_ids" => released.map(&:id) }
        end

        private

        def from_states = rows.map { |row| row.fetch("from") }
      end
    end
  end
end
