module Leverage
  # The rule checks a gate plans and what happens to them (PRD L360 to
  # L423; milestone 4 plan §2.1, RE-1, RE-7, RE-9): the only writer of
  # rule_checks and rule_check_attempts, and the only emitter of check.*.
  # A check's reason and an override's reason stay on the row (L221).
  #
  # First version (milestone 4 plan §4, the hand-over table): every call
  # does nothing; write answers [] and the others nil. WP4 writes it.
  module RuleChecks
    module_function

    # Writes an Evaluation's checks for task, each with its first attempt,
    # and check.finished for an app check or check.queued for a model one
    # (rules 5 and 6), under pending when the command waits. Returns the
    # RuleCheck rows in the order of evaluation.checks, so a PlannedJob's
    # rule_check_ref and a PlannedHold's index find theirs.
    def write(ctx, evaluation, task:, pending: nil)
      []
    end

    # The attempt that job runs has started: seat claimed it
    # (check.started).
    def start(ctx, check, job:, seat:)
      nil
    end

    # The attempt finished with a checker's result, its reason, and the
    # tokens and spend it reported (check.finished). Returns the Event.
    def finish(ctx, check, result:, reason:, tokens: nil, spend: nil)
      nil
    end

    # The check ends in error after its second miss (check.finished,
    # result error). Returns the Event.
    def error(ctx, check)
      nil
    end

    # The check is withdrawn: its rule was turned off or removed, or its
    # waiting command was ended (check.finished, result withdrawn).
    # Returns the Event.
    def withdraw(ctx, check)
      nil
    end

    # The owner lets the check through once, with who, when and why
    # (check.overridden, L423). Returns the Event.
    def override(ctx, check, user:, reason:)
      nil
    end

    # A new attempt of the check, run by job (check.queued): after a miss,
    # a re-run, or the orchestrator's return. Returns the
    # RuleCheckAttempt.
    def new_attempt(ctx, check, job:)
      nil
    end
  end
end
