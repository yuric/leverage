module Leverage
  # What happens to a piece of work when its credential stops or becomes
  # available (PRD L650-L703; milestone 3 plan §2.1 rules 5 to 8, HE-2,
  # HE-4, HE-9 to HE-13, HD-1). The only caller of Holds for the two
  # credential reasons. Every event goes through ctx.emit, inside the
  # command's transaction.
  #
  # First version (milestone 3 plan §4, the hand-over table): every public
  # method has its final name and arguments and does nothing. WP3 writes
  # them; a package that calls one before then asserts in its own tests
  # that it called it with the right arguments.
  module Handoff
    # How many open credential holds reevaluate reads at a time (HE-10).
    BATCH = 100

    module_function

    # Rule 5: marks the stopped credential (a limit: limited_since, and
    # limited_until as HE-22 and HE-32 say; a sign-out: state signed_out)
    # and writes the first event, credential.limit_reached or
    # credential.signed_out, with the credential as subject.
    #
    # kind        - "limit" or "signed_out".
    # task:, review: - the work the run was doing: the task, or the review
    #               (whose task the event is written on).
    # window:, reset_at:, observed_at: - a limit's report.
    #
    # Returns the first Event.
    def interrupt(ctx, credential:, seat:, kind:, task: nil, review: nil, window: nil, reset_at: nil, observed_at: nil)
      nil
    end

    # Rule 6: with a next candidate (Candidates.next_after), switch; with
    # none, a task's hold (credential_signed_out or credential_limit, its
    # credential and its item as HE-4, HE-12 and HE-13 say) or a review's
    # release (review.released caused by cause).
    #
    # stopped - the Credential that stopped.
    # cause   - the first Event, which the events written here name.
    #
    # Returns the Events it wrote.
    def continue_or_hold(ctx, seat:, stopped:, cause:, task: nil, review: nil)
      nil
    end

    # Rule 7 and HE-10, HE-11: looks again at the open credential holds,
    # oldest first in bounded batches, and closes those that can go on
    # (hold.closed, credential.switched when the credential differs,
    # inbox.resolved, then SeatRuns.ensure_run_on). Opens the "Account
    # signed out" item beside a credential_limit hold that signed_out has
    # left with no due time, and resolves an "Account signed out" item
    # whose account verified names.
    #
    # tasks:      - the tasks to look at; nil is every task of the
    #               workspace with an open credential hold.
    # cause:      - the Event the closing events name as their cause.
    # verified:   - a Credential just verified or added, or nil.
    # signed_out: - a Credential just found signed out, or nil.
    # choice:     - the inbox.resolved choice (HE-29), or nil.
    #
    # Returns the Events it wrote.
    def reevaluate(ctx, tasks: nil, cause: nil, verified: nil, signed_out: nil, choice: nil)
      nil
    end

    # Hands a piece of work to another credential: credential.switched
    # (subject to, from_credential_id from, the model of HE-5, the seat and
    # the review), the work's recorded credential becomes to, and
    # SeatRuns.ensure_run_on.
    #
    # Returns the credential.switched Event.
    def switch(ctx, seat:, to:, from:, cause:, task: nil, review: nil)
      nil
    end
  end
end
