module Leverage
  # A pending transition's life (PRD L374 to L384; milestone 4 plan §2.1,
  # RE-2 to RE-6, rule 11): a command that waits on a blocking model check
  # is stored whole with its request, and later completes, is refused or
  # is cancelled inside whatever command or timer brings its last result,
  # as its requester (Transitions::Context#as_requester). The only writer
  # of pending_transitions and of a pending commands row's later outcome.
  # cancel is the one place a waiting command is ended from outside (rule
  # 11): its checks and jobs are withdrawn, their check_error and
  # rerun_limit holds closed, its request emptied, and its requester's
  # command refused with the code and marked notify.
  #
  # First version (milestone 4 plan §4, the hand-over table): every call
  # does nothing and answers nil. WP4 writes it.
  module PendingTransitions
    module_function

    # Stores entry's command as pending (Gate, when evaluation is :pending):
    # the frozen rule versions, the requester and its key, and params, the
    # request it will complete with (RE-2). Returns the PendingTransition.
    def store(ctx, entry, evaluation, params)
      nil
    end

    # Gates the transition again on trigger, a Gating::Trigger (step 6,
    # rule 9), and completes, refuses, cancels or keeps it pending. Returns
    # the Gating::Decision.
    def reenter(ctx, pending, trigger)
      nil
    end

    # Performs the stored command as its requester, with cause_id the
    # check.finished or check.overridden that settled it (L241).
    def complete(ctx, pending, cause_id:)
      nil
    end

    # Refuses the stored command with decision's first failure (rule 7).
    def refuse(ctx, pending, decision, cause_id:)
      nil
    end

    # Ends the waiting command from outside (rule 11): code is one of
    # RC-17's three (task_cancelled, lease_expired, invalid_state).
    def cancel(ctx, pending, code)
      nil
    end

    # The task's pending transition (state pending), or nil.
    def of(task)
      nil
    end
  end
end
