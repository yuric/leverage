module Leverage
  # "No reviewer is eligible" (PRD L448, L803; milestone 4 plan RD-51,
  # SM-42): for tasks In review with no reviewer, whether any connected
  # reviewer may take the review now; opens and resolves the item. After a
  # command in REEVALUATED_BY it runs on what that command changed
  # (Transitions calls after_command after every perform), and the
  # reviewer_eligibility timer runs it on every sweep.
  #
  # First version (milestone 4 plan §4, the hand-over table): nothing runs
  # after any command, and every call does nothing. WP9 writes it.
  module ReviewerEligibility
    # The commands after which it runs (the state rows that carry its side
    # events, SM-42).
    REEVALUATED_BY = [].freeze

    module_function

    # Called by Transitions after a command's perform, with its entry.
    def after_command(ctx, entry)
      nil
    end

    # Opens or resolves the item for each task In review with no reviewer,
    # or only those of task_ids. Returns the Events it wrote.
    def reevaluate(ctx, task_ids: nil)
      nil
    end
  end
end
