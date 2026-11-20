module Leverage
  # A seat's run (PRD L121, L148, L590-L591, L823, L914; milestone 2 plan
  # §2.1, IN-17, IN-30, IN-40, IF-21; milestone 3 plan §0.1 fact 10): the
  # one place that changes seats.run_state and ends or issues a seat's
  # token. What a started, stopped or removed run changes, a review the
  # seat held, a Working task it held, and the start_seat requests. Called
  # inside a command's transaction by connect_seat, start_seat,
  # issue_seat_token, issue_helper_token, report_run_started,
  # report_run_stopped, remove_seat, the seat_run_placement timer, and the
  # handoff (Handoff, the reports, a closing hold, a fresh lease) through
  # ensure_run_on and ended_by_interruption; every event goes through
  # ctx.emit.
  #
  # A lease already past its due time is left to its timer
  # (builder_lease_expiry, review_lease_expiry), which writes the
  # lease_expired event the log needs; only a live or paused lease is
  # released here.
  #
  # Milestone 4 (plan §2.1 rule 11): whatever this module takes from a seat
  # first ends the waiting command the seat has on it, through
  # PendingTransitions.cancel with invalid_state: the pending pass of a
  # review a stopped run or a removed seat releases, the pending submit of
  # the Working task a removed or disabled seat releases, and the
  # provisional claim a removed or disabled seat holds. The cancel comes
  # before the release's own event.
  module SeatRuns
    # Where a seat's run belongs now (milestone 3 plan HD-1, HD-4): the
    # credential, and the work it continues (a Task, a Review or nil). A
    # nil credential means no run belongs anywhere now: the seat connects
    # on its own, or its task waits under a credential hold (HE-21).
    Placement = Data.define(:credential, :work)

    # The helper request states of a request still to be finished.
    UNFINISHED = %w[queued picked_up].freeze

    # The hold reasons that wait for an account to come back (L692-L699).
    CREDENTIAL_REASONS = %w[credential_limit credential_signed_out].freeze

    # The holds bound to the seat that holds the task (SM-15): they close
    # when the seat loses the task (state_machine.json, remove_seat's
    # holds_closed).
    SEAT_BOUND_REASONS = (%w[seat_paused] + CREDENTIAL_REASONS).freeze

    # The run ends that seat_run_placement starts a wanted seat again
    # after (HD-4). Any other end waits for the app to be opened (IN-30).
    INTERRUPTIONS = %w[limit signed_out].freeze

    module_function

    # The account a seat's run belongs on now, and the work it continues
    # (HD-1, HD-4):
    #
    #   a Working task the seat holds, with no credential hold: the
    #     credential recorded for the task, and the task;
    #   the same under a credential hold: no credential, and the task;
    #   a review the seat holds: the credential recorded for the review,
    #     and the review;
    #   nothing held: the first available candidate, else its own.
    #
    # A seat that connects on its own has neither. at is the time
    # availability is read at.
    #
    # Returns a Placement.
    def placement(seat, at: Time.current)
      own = seat.credential_id && Credential.find_by(id: seat.credential_id, workspace_id: seat.workspace_id)
      return Placement.new(credential: nil, work: nil) unless own

      task = Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id, state: %w[working finishing])
        .order(:created_at, :id).first
      if task
        return Placement.new(credential: nil, work: task) if credential_hold?(task)

        return Placement.new(credential: recorded(seat, task.credential_id) || own, work: task)
      end

      review = Review.where(workspace_id: seat.workspace_id, reviewer_seat_id: seat.id, verdict: nil)
        .order(:created_at, :id).first
      return Placement.new(credential: recorded(seat, review.credential_id) || own, work: review) if review

      Placement.new(credential: Candidates.first_available(seat, nil, at) || own, work: nil)
    end

    # Queues one start_seat request for the seat on credential, naming the
    # work to continue (HD-1), when the seat's run is not on credential or
    # it has no run. Nothing is queued while an unfinished start_seat for
    # the seat exists, for a seat that is not wanted running (the owner's
    # Stop and Remove are kept), or for a seat that connects on its own.
    #
    # work - a Task, a Review or nil.
    #
    # Returns the HelperRequest it queued, or nil.
    def ensure_run_on(ctx, seat, credential, work)
      seat = Seat.find(seat.id)
      return nil if credential.nil? || seat.credential_id.nil? || seat.removed_at || !seat.wanted_running
      return nil if seat.run_credential_id == credential.id
      return nil if unfinished_start?(seat)

      start(ctx, seat, Placement.new(credential: credential, work: work))
    end

    # Records that the seat's run ended for a limit or a sign-out (HD-3,
    # HD-10), as the report's entry says: run state stopped, the token
    # ended, no run credential, and the reason kept. It releases nothing:
    # the report's state-table row says what happens to the work.
    #
    # reason - a RunStoppedReport.stop_reason value ("limit", "signed_out").
    def ended_by_interruption(seat, reason)
      seat.update!(run_state: "stopped", token_hash: nil, run_credential_id: nil, run_stop_reason: reason)
    end

    # A seat the app runs has just been connected (IN-30): no run yet,
    # wanted running, and its start queued where SeatRuns.placement puts
    # it. A seat that connects on its own has no run the app starts, and
    # nothing changes.
    #
    # Returns the start_seat HelperRequest, or nil.
    def connected(ctx, seat)
      return nil unless seat.credential_id

      seat.update!(run_state: "stopped", wanted_running: true)
      start(ctx, seat, placement(seat, at: ctx.at))
    end

    # The seat's fresh token for the start_seat request the helper holds
    # (IN-11, IN-17, PK-7): its digest replaces the seat's, which ends the
    # previous token, and the seat's run is on the start's credential from
    # now (HD-3). Returns the token, which is shown once and never stored.
    def issue_token(seat, start)
      token = Tokens.issue(:seat)
      seat.update!(token_hash: Tokens.digest(token), run_credential_id: start.credential_id || seat.credential_id)
      token
    end

    # The helper reported the seat's run started.
    def run_started(seat)
      seat.update!(run_state: "running")
    end

    # The credential a run of the seat may report: the one its token was
    # issued for (HD-3), or the seat's own for a token issued before that
    # was recorded.
    def run_credential_id(seat) = seat.run_credential_id || seat.credential_id

    # A new helper token brings the server and the Mac back in step
    # (IN-30): every seat still marked running is treated as stopped, as
    # the app; no seat's run is on a credential any more, since the
    # previous helper's runs are gone; and every seat wanted running gets a
    # start_seat request where SeatRuns.placement puts it (HD-1), none
    # while its task waits under a credential hold.
    def reconcile(ctx)
      seats = Seat.where(workspace_id: ctx.workspace.id)
      seats.where(run_state: "running").order(:created_at).each do |seat|
        run_stopped(ctx, seat, actor_kind: "app", actor_id: nil)
      end
      seats.where.not(run_credential_id: nil).update_all(run_credential_id: nil)
      seats.where(wanted_running: true, removed_at: nil).where.not(credential_id: nil).order(:created_at).each do |seat|
        start(ctx, seat, placement(seat, at: ctx.at))
      end
    end

    # The owner's Start (start_seat, IN-30): the seat is wanted running and
    # gets a start where SeatRuns.placement puts it. While a start of the
    # seat is unfinished and the seat was already wanted running, that one
    # is the answer; an unfinished start of a seat no longer wanted running
    # is stale (the owner's Stop came after it): it is failed, as a new
    # helper token fails it, and a new one is queued. A seat whose task
    # waits under a credential hold gets none: the hold's close starts it
    # (HE-21).
    #
    # Returns the start_seat HelperRequest, or nil.
    def owner_start(ctx, seat)
      unfinished = HelperRequest.where(seat_id: seat.id, kind: "start_seat", state: UNFINISHED).order(:requested_at).to_a
      request = unfinished.first if seat.wanted_running
      unless request
        unfinished.each do |stale|
          stale.update!(state: "failed", finished_at: ctx.at, result: STALE_RESULT, updated_at: ctx.at)
        end
        request = start(ctx, seat, placement(seat, at: ctx.at))
      end
      seat.update!(wanted_running: true)
      request
    end

    # The result of a start failed as stale: no check ran and nothing was
    # reported (the result a new helper token gives, IN-30).
    STALE_RESULT = { "outcome" => "failed", "checks" => [], "tool_version" => nil, "plan" => nil,
                     "account_email" => nil }.freeze

    # A seat removed (IN-17, IN-40): its token answers no more from this
    # moment, it is no longer wanted running, a Working task it holds is
    # released with seat_removed (caused by removed, the seat.removed
    # Event), a review it holds is released, and a seat the app runs gets
    # a stop_seat request. A pending submit, a pending pass or a
    # provisional claim of the seat is cancelled first (rule 11).
    #
    # Returns the stop_seat HelperRequest, or nil.
    def removed(ctx, seat, cause:)
      seat.update!(token_hash: nil, wanted_running: false)
      release_working_task(ctx, seat, reason: "seat_removed", cause: cause)
      held_reviews(ctx, seat).each do |review|
        cancel_pending(ctx, Task.find(review.task_id))
        release_review(ctx, review)
      end
      seat.credential_id && queue(ctx, "stop_seat", seat: seat)
    end

    # A seat's run has stopped, or is treated as stopped (IN-30): run state
    # stopped, the token ended (IN-17), and a review the seat holds released
    # so another reviewer can claim it (IF-21, L914), after its pending pass,
    # if any, is cancelled (rule 11). A builder's task keeps its lease until
    # the lease ends (L121), and its pending submit with it. wanted_running
    # is not touched:
    # a run that dies on its own is started again only by the helper's next
    # token.
    #
    # The seat's run is on no credential any more, and it keeps why it
    # ended (milestone 3 plan HD-3, HD-10).
    #
    # reason: - the RunStoppedReport.stop_reason; nil keeps the last one
    #   (a run a new helper token treats as stopped ended for no known
    #   reason).
    # actor_kind:, actor_id: - who the review.released is written as;
    #   default the request's caller.
    #
    # Returns the events it wrote.
    def run_stopped(ctx, seat, reason: nil, **actor)
      seat.update!(run_state: "stopped", token_hash: nil, run_credential_id: nil,
        run_stop_reason: reason || seat.run_stop_reason)
      held_reviews(ctx, seat).map do |review|
        cancel_pending(ctx, Task.find(review.task_id))
        release_review(ctx, review, **actor)
      end
    end

    # Releases a review: no reviewer, no lease; the task stays In review.
    # Returns the review.released Event.
    def release_review(ctx, review, **actor)
      review.update!(reviewer_seat_id: nil, lease_due_at: nil, lease_time_left_while_paused: nil)
      task = Task.find(review.task_id)
      ctx.emit("review.released", task: task, subject: review, payload: {}, **actor)
    end

    # Releases the Working task a seat holds to Ready (L148), with reason
    # seat_removed or seat_disabled: no holder, no builder and no lease, as
    # every return to Ready (Release, the builder lease's expiry; the PRD's
    # replay list clears the builder there). The seat-bound holds of the
    # task then close (SM-15, milestone 3 plan §2.1 rule 7) through
    # Holds.close_seat_bound, after task.released and caused by it; the
    # cause of the wait_ready step that opens (HE-35) is on the hold.closed
    # that opens it when a seat-bound hold was open, else on
    # task.released.
    #
    # Milestone 4 (rule 11): a provisional claim the seat holds in Ready is
    # cancelled (cancel_provisional_claim); the claim has no lease and no
    # task.claimed, so it gets no task.released, and the cancel is all the
    # task gets. A pending submit of the Working task is cancelled before
    # task.released is written.
    #
    # Returns the task.released Event, or nil when the seat holds no
    # Working task with a live or paused lease.
    def release_working_task(ctx, seat, reason:, cause: nil)
      cancel_provisional_claim(ctx, seat)
      task = Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id, state: "working").order(:created_at).first
      return nil unless task && lease_live?(ctx, task)

      cancel_pending(ctx, task)
      bound = Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil, reason: SEAT_BOUND_REASONS)
        .exists?
      task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil, resume_pending_since: nil, lease_due_at: nil,
        lease_time_left_while_paused: nil)
      wait_cause = Candidates.wait_cause(task, ctx.at)
      released = ctx.emit("task.released", task: task, cause_id: cause&.id,
        payload: { reason: reason, wait_cause: (wait_cause unless bound) })
      Holds.close_seat_bound(ctx, task, cause: released, wait_cause: wait_cause) if bound
      released
    end

    # Cancels the provisional claim the seat holds, if it holds one (PRD
    # L390, SM-14): a Ready task whose holder is the seat, under its pending
    # claim, with invalid_state (rule 11). The claim has no lease, so no
    # timer ends it; a removed, disabled or paused claimant does, and no
    # hold opens for it.
    #
    # Returns nothing worth reading.
    def cancel_provisional_claim(ctx, seat)
      task = Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id, state: "ready").order(:created_at).first
      cancel_pending(ctx, task) if task
    end

    # Ends the waiting command of the task, if it has one, because a seat's
    # run or the seat itself took the task or the review from the
    # requester (rule 11): PendingTransitions.cancel with invalid_state.
    # Nothing happens for a task with no pending transition.
    def cancel_pending(ctx, task)
      pending = PendingTransitions.of(task)
      PendingTransitions.cancel(ctx, pending, "invalid_state") if pending
    end

    # The non-secret inputs of a start_seat request (IN-22): the seat's
    # role, provider, model and effort, an empty model or effort as null
    # (the tool's default, IN-29). Never the seat's name.
    def start_params(seat)
      { "role" => seat.role, "provider" => seat.provider, "model" => seat.model.presence, "effort" => seat.effort.presence }
    end

    # Queues the start_seat request that puts the seat's run where
    # placement says (HD-1): the credential in the request's own column;
    # in params the role, the credential's provider, the model and effort
    # of HE-5 (Candidates.model_for, effort_for: the seat's within its
    # provider group, the credential's in another; empty is null, the
    # tool's own default), and task_id or review_id, the work to continue.
    # Never a name or a token. Returns the HelperRequest, or nil when the
    # placement has no credential.
    def start(ctx, seat, placement)
      credential = placement.credential
      return nil unless credential

      params = { "role" => seat.role, "provider" => credential.provider,
                 "model" => Candidates.model_for(seat, credential), "effort" => Candidates.effort_for(seat, credential) }
      case placement.work
      when Task then params["task_id"] = placement.work.id
      when Review then params["review_id"] = placement.work.id
      end
      queue(ctx, "start_seat", seat: seat, credential_id: credential.id, params: params)
    end

    # Whether a start_seat request for the seat is still to be finished.
    def unfinished_start?(seat)
      HelperRequest.where(seat_id: seat.id, kind: "start_seat", state: UNFINISHED).exists?
    end

    # Whether a credential hold is open on the task.
    def credential_hold?(task)
      Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil, reason: CREDENTIAL_REASONS).exists?
    end

    # The credential of a seat's workspace an id names, or nil.
    def recorded(seat, credential_id)
      credential_id && Credential.find_by(id: credential_id, workspace_id: seat.workspace_id)
    end

    # Queues a helper request (IN-22, IN-23). Returns the HelperRequest.
    def queue(ctx, kind, seat: nil, credential_id: seat&.credential_id, params: {})
      HelperRequest.create!(workspace_id: ctx.workspace.id, kind: kind, seat_id: seat&.id, credential_id: credential_id,
        state: "queued", requested_at: ctx.at, params: params, created_at: ctx.at, updated_at: ctx.at)
    end

    # The reviews a seat holds with a live or paused lease.
    def held_reviews(ctx, seat)
      Review.where(workspace_id: seat.workspace_id, reviewer_seat_id: seat.id, verdict: nil).order(:created_at)
        .select { |review| lease_live?(ctx, review) }
    end

    # A lease that is paused, or due after now. One past its due time has
    # ended (EN-14) and belongs to its timer.
    def lease_live?(ctx, subject)
      subject.lease_due_at.nil? || subject.lease_due_at > ctx.at
    end
  end
end
