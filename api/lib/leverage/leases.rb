module Leverage
  # Leases (PRD L116-L123): a builder's lease on a task and a reviewer's on
  # a review, both kept in the subject's own two columns:
  #
  #   running  lease_due_at set, lease_time_left_while_paused null
  #   paused   lease_due_at null, lease_time_left_while_paused the time the
  #            clock had left when it stopped (a hold that pauses the lease)
  #   none     both null
  #
  # A lease is due from its due time on, and never while paused (L122). A
  # due lease is ended by its timer (Timers, the two *_lease_expiry
  # entries), which every command on the task runs first and the sweep runs
  # for the rest; until then a read treats it as ended (live?, EN-14) and
  # writes nothing.
  #
  # Every writer here runs inside a command, under the workspace lock, with
  # ctx.at as the time. Who holds the lease (tasks.holder_seat_id,
  # reviews.reviewer_seat_id) is the entries' to set; when a hold pauses
  # or restarts a clock is Holds' (WP4).
  module Leases
    # The events that give a builder a lease on a task: task.claimed names
    # the seat in seat_id, and every event that grants a fresh lease names
    # it in lease_seat_id (state_machine.json, builder_lease).
    BUILDER_GRANT = "task.claimed".freeze

    module_function

    # Grants a lease on a task or a review: due one lease length after
    # ctx.at, or, with paused: true (a lease granted while a hold that
    # pauses it is open, L163), paused with the whole length left.
    def grant(ctx, subject, paused: false)
      length = ctx.workspace.lease_length_seconds
      if paused
        subject.update!(lease_due_at: nil, lease_time_left_while_paused: length.seconds)
      else
        subject.update!(lease_due_at: ctx.at + length, lease_time_left_while_paused: nil)
      end
    end

    # Renews a lease (a heartbeat): due one lease length after ctx.at. A
    # paused lease stays paused, with the whole length left: a heartbeat
    # does not restart a clock a hold stopped.
    def renew(ctx, subject)
      grant(ctx, subject, paused: paused?(subject))
    end

    # Ends a lease: no due time and no pause.
    def end_lease(_ctx, subject)
      subject.update!(lease_due_at: nil, lease_time_left_while_paused: nil)
    end

    # Stops a running lease's clock, keeping the time it had left (none for
    # a lease already past its due time). A paused lease, or no lease, is
    # left as it is.
    def pause(ctx, subject)
      return unless subject.lease_due_at && !paused?(subject)

      left = [ subject.lease_due_at - ctx.at, 0 ].max
      subject.update!(lease_due_at: nil, lease_time_left_while_paused: left.seconds)
    end

    # Starts a paused lease's clock again: due the time it had left after
    # ctx.at. A lease that is not paused is left as it is.
    def restart(ctx, subject, at: ctx.at) # rubocop:disable Lint/UnusedMethodArgument
      return unless paused?(subject)

      subject.update!(lease_due_at: ctx.at + subject.lease_time_left_while_paused.to_f,
        lease_time_left_while_paused: nil)
    end

    # Whether the lease's clock is stopped.
    def paused?(subject)
      !subject.lease_time_left_while_paused.nil?
    end

    # Whether the lease has reached its due time at the given time: what a
    # timer ends. Never for a paused lease or no lease.
    def due?(subject, at)
      !paused?(subject) && !subject.lease_due_at.nil? && subject.lease_due_at <= at
    end

    # Whether there is a lease that has not reached its due time at the
    # given time, running or paused. A read uses it: a lease past its due
    # time counts as ended before its timer has written so (EN-14).
    def live?(subject, at)
      paused?(subject) || (!subject.lease_due_at.nil? && subject.lease_due_at > at)
    end

    # Whether the seat's latest lease on the task or review ended with
    # task.lease_expired or review.lease_expired and it has no newer lease
    # on it (EN-15): such a seat is refused lease_expired, any other seat
    # not_holder. Read from the events, in seq order.
    #
    # subject - a Task (the builder's lease) or a Review (the reviewer's).
    # seat    - a Seat or a seat id.
    def ended_by_expiry?(subject, seat)
      seat_id = seat.respond_to?(:id) ? seat.id : seat
      subject.is_a?(Review) ? review_lease_expired?(subject, seat_id) : task_lease_expired?(subject, seat_id)
    end

    def task_lease_expired?(task, seat_id)
      holder = nil
      expired = false
      Event.where(workspace_id: task.workspace_id, task_id: task.id).order(:seq).each do |event|
        grantee = builder_grantee(event)
        if grantee
          holder = grantee
          expired = false if grantee == seat_id
        elsif event.type == "task.lease_expired"
          expired = true if holder == seat_id
          holder = nil
        end
      end
      expired
    end

    def review_lease_expired?(review, seat_id)
      holder = nil
      expired = false
      Event.where(workspace_id: review.workspace_id, task_id: review.task_id, subject_kind: "review", subject_id: review.id)
        .order(:seq).each do |event|
        case event.type
        when "review.started"
          holder = event.actor_id
          expired = false if holder == seat_id
        when "review.lease_expired"
          expired = true if holder == seat_id
          holder = nil
        end
      end
      expired
    end

    def builder_grantee(event)
      return event.payload["seat_id"] if event.type == BUILDER_GRANT

      event.payload["lease_seat_id"]
    end
  end
end
