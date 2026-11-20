module Leverage
  # The transition function: the only public way to change anything
  # (PRD L215-L222; milestone 2 plan §2.1, E-16, E-17, EN-16, EN-17). One
  # entry per command (Transitions::Table), and one pipeline for all:
  #
  #   1. A transaction, read committed. WorkspaceLock takes the workspace
  #      row FOR UPDATE as its first statement and reads the clock in a
  #      second: at, shared by every event of the command.
  #   2. Idempotency.find: a stored row with the same request hash answers
  #      its outcome and nothing else runs; another hash is KeyReused.
  #   3. Timers.apply_due: every timer due on the target task and on what
  #      the calling seat holds, each through its own entry, before the
  #      command's own events.
  #   4. The entry's refusals; Precedence picks the first by the registry.
  #   5. At a row with a hook, Gate asks Gating (EN-5).
  #   6. entry.perform changes rows and writes events through EventLog.
  #   7. Idempotency.store writes the commands row, for a refusal too, so
  #      the timer events of step 3 commit with it (test 7).
  #   8. Commit; CommandLog writes one line.
  #
  # A command the app runs (a timer, the sweep) has no caller and no key:
  # steps 2 and 7 are skipped.
  module Transitions
    # An id outside the caller's workspace: 404 not_found (IF-3, IN-13).
    class NotFound < StandardError; end

    # What the contract's shape rules refuse that a schema cannot say:
    # 422 invalid (IF-3), like a body that fails its schema.
    class Invalid < StandardError; end

    class << self
      # Tests only: a StandIn that answers apply instead of the pipeline.
      attr_accessor :stand_in

      # Runs one command and returns its Outcome. Raises
      # Idempotency::KeyReused, NotFound, Invalid, Table::UnknownCommand,
      # EventLog::InvalidEvent or ActiveRecord::RecordNotFound (an unknown
      # workspace); every one of them rolls the whole command back.
      def apply(request)
        return stand_in.apply(request) if stand_in

        run(request)
      end

      # Tests only: answers apply from the stand-in inside the block.
      def with_stand_in(stand_in)
        saved = self.stand_in
        self.stand_in = stand_in
        yield
      ensure
        self.stand_in = saved
      end

      private

      def run(request)
        entry_class = Table.entry_for(request.command)
        started = monotonic
        timing = { lock_wait: 0.0, writes: 0.0 }
        outcome = ActiveRecord::Base.transaction(requires_new: true) do
          ctx = context(request, timing)
          stored = Idempotency.find(request)
          next stored if stored

          Timers.apply_due(ctx)
          entry = entry_class.new(request.command)
          entry.load(ctx)
          refusal = Precedence.first(entry.refusals(ctx))
          outcome = if refusal
            Outcome.refused(refusal)
          else
            Gate.call(ctx, entry)
            entry.perform(ctx)
            Outcome.completed(entry.result, once: entry.once)
          end
          Idempotency.store(ctx, request, outcome) unless request.by_app?
          timing[:writes] = ctx.write_seconds
          outcome
        end
        CommandLog.write(request, outcome, lock_wait: timing[:lock_wait], writes: timing[:writes],
          total: monotonic - started)
        outcome
      end

      def context(request, timing)
        locking = monotonic
        if request.workspace_id
          workspace, at = WorkspaceLock.take(request.workspace_id)
        else
          workspace = nil
          at = WorkspaceLock.take_setup
        end
        timing[:lock_wait] = monotonic - locking
        Context.new(request: request, workspace: workspace, at: at)
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
