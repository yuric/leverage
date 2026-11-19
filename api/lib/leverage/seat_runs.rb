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
    module_function

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
    # seat_removed or seat_disabled: no holder and no lease; the task keeps
    # its builder seat. Returns the task.released Event, or nil when the
    # seat holds no Working task with a live or paused lease.
    def release_working_task(ctx, seat, reason:, cause: nil)
      task = Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id, state: "working").order(:created_at).first
      return nil unless task && lease_live?(ctx, task)

      task.update!(state: "ready", holder_seat_id: nil, lease_due_at: nil, lease_time_left_while_paused: nil)
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
