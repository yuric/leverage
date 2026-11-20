module Leverage
  # What a stopped run and a removed seat change (PRD L121, L148, L590-L591,
  # L823, L914; milestone 2 plan §2.1, IN-17, IN-30, IN-40, IF-21): the run
  # state, the seat's token, a review the seat held, a Working task it held,
  # and the inputs of a start_seat request. Called inside a command's
  # transaction by report_run_stopped, issue_helper_token, remove_seat,
  # connect_seat and start_seat; every event goes through ctx.emit.
  #
  # A lease already past its due time is left to its timer
  # (builder_lease_expiry, review_lease_expiry), which writes the
  # lease_expired event the log needs; only a live or paused lease is
  # released here.
  module SeatRuns
    # Where a seat's run belongs now (milestone 3 plan HD-1, HD-4): the
    # credential, and the work it continues (a Task, a Review or nil).
    Placement = Data.define(:credential, :work)

    module_function

    # The account a seat's run belongs on now, and the work it continues
    # (HD-1, HD-4). First version (milestone 3 plan §4, the hand-over
    # table, WP5 finishes it): the seat's own credential (nil for a seat
    # that connects on its own) and no work.
    #
    # Returns a Placement.
    def placement(seat)
      credential = seat.credential_id && Credential.find_by(id: seat.credential_id, workspace_id: seat.workspace_id)
      Placement.new(credential: credential, work: nil)
    end

    # Queues one start_seat request for the seat on credential, naming the
    # work to continue, when its run is not on credential or it has no
    # run, unless an unfinished start_seat for the seat exists (HD-1).
    # First version: queues nothing.
    #
    # work - a Task, a Review or nil.
    #
    # Returns the HelperRequest it queued, or nil.
    def ensure_run_on(ctx, seat, credential, work)
      nil
    end

    # Records that the seat's run ended for a limit or a sign-out (HD-3,
    # HD-10): no run credential, and the reason kept. First version: does
    # nothing.
    #
    # reason - a RunStoppedReport.stop_reason value.
    def ended_by_interruption(seat, reason)
      nil
    end

    # A seat's run has stopped, or is treated as stopped (IN-30): run state
    # stopped, the token ended (IN-17), and a review the seat holds released
    # so another reviewer can claim it (IF-21, L914). A builder's task keeps
    # its lease until the lease ends (L121). wanted_running is not touched:
    # a run that dies on its own is started again only by the helper's next
    # token.
    #
    # actor_kind:, actor_id: - who the review.released is written as;
    #   default the request's caller.
    #
    # Returns the events it wrote.
    def run_stopped(ctx, seat, **actor)
      seat.update!(run_state: "stopped", token_hash: nil)
      held_reviews(ctx, seat).map { |review| release_review(ctx, review, **actor) }
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
    # replay list clears the builder there). Returns the task.released
    # Event, or nil when the seat holds no Working task with a live or
    # paused lease.
    def release_working_task(ctx, seat, reason:, cause: nil)
      task = Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id, state: "working").order(:created_at).first
      return nil unless task && lease_live?(ctx, task)

      task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil, resume_pending_since: nil, lease_due_at: nil,
        lease_time_left_while_paused: nil)
      ctx.emit("task.released", task: task, cause_id: cause&.id, payload: { reason: reason, wait_cause: nil })
    end

    # The non-secret inputs of a start_seat request (IN-22): the seat's
    # role, provider, model and effort, an empty model or effort as null
    # (the tool's default, IN-29). Never the seat's name.
    def start_params(seat)
      { "role" => seat.role, "provider" => seat.provider, "model" => seat.model.presence, "effort" => seat.effort.presence }
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
