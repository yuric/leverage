module Leverage
  # Leases (PRD L116-L123): a builder's lease on a task and a reviewer's on
  # a review.
  #
  # First version, by WP1 (milestone 2 plan §4): grant, renew and end_lease
  # set and clear the due time only, and ended_by_expiry? is already the
  # real read of EN-15. WP5 owns this file from here on, adds the rest and
  # leaves ended_by_expiry? as it is.
  module Leases
    # The events that give a builder a lease on a task: task.claimed names
    # the seat in seat_id, and every event that grants a fresh lease names
    # it in lease_seat_id (state_machine.json, builder_lease).
    BUILDER_GRANT = "task.claimed".freeze

    module_function

    # Grants a lease on a task or a review: due one lease length after
    # ctx.at.
    def grant(ctx, subject)
      subject.update!(lease_due_at: ctx.at + ctx.workspace.lease_length_seconds, lease_time_left_while_paused: nil)
    end

    # Renews a lease: due one lease length after ctx.at.
    def renew(ctx, subject)
      grant(ctx, subject)
    end

    # Ends a lease: no due time.
    def end_lease(_ctx, subject)
      subject.update!(lease_due_at: nil, lease_time_left_while_paused: nil)
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
