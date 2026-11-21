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
  #      command's own events (a review lease's end with the item it
  #      causes, SM-42, which commit whatever the command then does).
  #   4. The entry's refusals; Precedence picks the first by the registry.
  #      A seat waiting on its task's pending transition answers pending to
  #      every command the registry does not allow while pending (RE-4).
  #   5. At a row with a hook, Gate asks Gating, writes what it planned and
  #      decides: perform, wait (a pending transition, 202) or the hook's
  #      failed-gate effect (milestone 4 plan §2.1, rules 1 to 8).
  #   6. entry.perform changes rows and writes events through EventLog;
  #      then ReviewerEligibility.after_command looks at what it changed
  #      (milestone 4 plan SM-42). Finishing.after_command runs once after
  #      the outer command's outcome is decided, including refusals (AE-2).
  #   7. Idempotency.store writes the commands row, for a refusal too, so
  #      the timer events of step 3 and the rule checks of step 5 commit
  #      with it (test 7, RE-7). A command whose key now names a pending
  #      transition (its own, or one run_as stored under it) answers
  #      pending, and its row is linked to the transition.
  #   8. Commit; CommandLog writes one line, with the time spent in Gate.
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

      # Runs another command's entry inside ctx's transaction, as requester
      # (a Seat, or the owner's User), with that requester's key and params:
      # how a planner's job result runs Complete contract as the planner,
      # with the result call's key (milestone 4 plan RE-6, §4 hand-over
      # table). It answers the command's outcome: :completed, :pending or
      # :refused.
      #
      # The entry's load and refusals (a pending answer among them, RE-4),
      # then its gate and perform, all as the requester
      # (Context#as_requester): its events carry the requester as actor and
      # key as command_id. When the gate waits, the transition is stored
      # under the requester and key, and the calling command, whose key it
      # is, answers pending (step 7).
      def run_as(ctx, command, requester:, key:, params:)
        requested = PendingTransitions::Requested.new(command: command.to_s, workspace_id: ctx.workspace.id,
          requester_kind: requester.is_a?(User) ? "owner" : "seat", requester_id: requester.id, command_key: key,
          params: params.to_h.deep_stringify_keys)
        ctx.as_requester(requested, cause_id: nil) do
          entry = Table.entry_for(command, allow_pending: true).new(command.to_s)
          entry.load(ctx)
          refusal = Precedence.first(refusals(ctx, entry))
          next :refused if refusal

          Gate.outcome(ctx, entry, Gate.call(ctx, entry)).outcome
        end
      end

      # Step 6 for an entry the gate lets through, at once or when its
      # pending transition completes: perform, then
      # ReviewerEligibility.after_command with what it changed.
      def perform(ctx, entry)
        entry.perform(ctx)
        ReviewerEligibility.after_command(ctx, entry)
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
        entry_class = Table.entry_for(request.command, allow_pending: true)
        started = monotonic
        timing = { lock_wait: 0.0, writes: 0.0, gate: 0.0 }
        outcome = ActiveRecord::Base.transaction(requires_new: true) do
          ctx = context(request, timing)
          stored = Idempotency.find(request, at: ctx.at)
          next stored if stored

          Timers.apply_due(ctx)
          entry = entry_class.new(request.command)
          entry.load(ctx)
          refusal = Precedence.first(refusals(ctx, entry))
          outcome = refusal ? Outcome.refused(refusal) : gated(ctx, entry, timing)
          Finishing.after_command(ctx)
          pending = PendingTransitions.for_request(request)
          outcome = Outcome.new(outcome: :pending) if pending && !outcome.refused?
          unless request.by_app?
            row = Idempotency.store(ctx, request, outcome)
            PendingTransitions.link(row, pending) if pending && outcome.outcome == :pending
          end
          timing[:writes] = ctx.write_seconds
          outcome
        end
        CommandLog.write(request, outcome, lock_wait: timing[:lock_wait], writes: timing[:writes],
          total: monotonic - started, gate: timing[:gate])
        outcome
      end

      # The entry's refusals and pending: for a seat waiting on its task's
      # pending transition (RE-4), and for a gated command on a task that
      # already waits on another (L373).
      def refusals(ctx, entry)
        codes = entry.refusals(ctx)
        waits = PendingTransitions.blocks?(ctx, entry.command) ||
          (Precedence.first(codes).nil? && PendingTransitions.taken?(ctx, entry))
        waits ? codes + [ "pending" ] : codes
      end

      # Steps 5 and 6: the gate, timed (CommandLog's gate_ms), then what it
      # decided.
      def gated(ctx, entry, timing)
        gating = monotonic
        result = Gate.call(ctx, entry)
        timing[:gate] = monotonic - gating
        Gate.outcome(ctx, entry, result)
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
