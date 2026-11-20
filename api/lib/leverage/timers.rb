module Leverage
  # The timers (PRD L118-L120; timers.json): which are due for a task, a
  # seat or a workspace, applied each through its own entry before a
  # command's own work (milestone 2 plan §2.1 step 3, EN-14, EN-17).
  #
  # Milestone 2 has the two lease timers and command_key_retention. The
  # task timers of later milestones (check and job timeouts, the credential
  # hold release) arrive with their entries; the workspace timers are fired
  # by the sweep (Sweep), never by a command.
  module Timers
    # The task timers a command applies first, by the subject whose due
    # time they read (timers.json).
    BUILDER_LEASE = "builder_lease_expiry".freeze
    REVIEW_LEASE = "review_lease_expiry".freeze

    # The params a path or a body names a task or a review by: /v1/tasks/{id}
    # and /v1/owner/tasks/{id} name a task, /v1/reviews/{id} a review.
    TARGET_PARAMS = %w[id task_id review_id].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # Applies every timer due on the request's target task (or the task of
    # its target review) and on every task or review the calling seat
    # holds, with effective_at the due time, actor app, no command_id, and
    # seq before the command's own events. A timer's own command (the
    # sweep's) applies itself and gets nothing here, and so does a command
    # with no workspace yet (create_owner).
    #
    # ctx - the command's Transitions::Context.
    #
    # Returns the Events it wrote.
    def apply_due(ctx)
      return [] if ctx.workspace.nil? || Transitions::Table::TIMERS.include?(ctx.request.command)

      apply_lease_timers(ctx, due_candidates(ctx))
    end

    # Applies the due lease timers on every task and review a seat holds,
    # as apply_due does for the caller: for a command that decides by what
    # another seat holds (fail_review asks whether the failed review's
    # builder is free). A lease ends at its due time (L120, EN-14), so the
    # answer must not depend on whether the sweep has run. Returns the
    # Events it wrote.
    def apply_held_by(ctx, seat)
      return [] unless seat

      workspace_id = ctx.workspace.id
      held_reviews = Review.where(workspace_id: workspace_id, reviewer_seat_id: seat.id, verdict: nil).select(:task_id)
      tasks = Task.where(workspace_id: workspace_id, holder_seat_id: seat.id)
        .or(Task.where(workspace_id: workspace_id, id: held_reviews)).order(:id).to_a
      apply_lease_timers(ctx, tasks)
    end

    # Applies the due lease timers a claim would otherwise find in its way:
    # for :task, every builder lease of the workspace past its due time (its
    # task goes back to Ready), for :review every review lease (the review
    # loses its reviewer), so what was due is claimable now, after its
    # lease_expired event at the due time. Returns the Events it wrote.
    def apply_claimable(ctx, kind)
      workspace_id = ctx.workspace.id
      tasks = if kind == :review
        due = Review.where(workspace_id: workspace_id, verdict: nil, lease_time_left_while_paused: nil)
          .where.not(reviewer_seat_id: nil).where(lease_due_at: ..ctx.at).select(:task_id)
        Task.where(workspace_id: workspace_id, id: due)
      else
        Task.where(workspace_id: workspace_id, lease_time_left_while_paused: nil).where(lease_due_at: ..ctx.at)
      end
      apply_lease_timers(ctx, tasks.order(:id).to_a)
    end

    # Runs the builder lease timer of each task whose lease is due, then
    # the review lease timer of each of their due reviews. Returns the
    # Events written.
    def apply_lease_timers(ctx, tasks)
      written = ctx.events.size
      tasks.each do |task|
        apply(ctx, Transitions::Entries::BuilderLeaseExpiry.new(BUILDER_LEASE, targets: [ task ])) if Leases.due?(task, ctx.at)
      end
      due_reviews_of(ctx, tasks.map(&:id)).each do |review|
        apply(ctx, Transitions::Entries::ReviewLeaseExpiry.new(REVIEW_LEASE, targets: [ review ]))
      end
      ctx.events.drop(written)
    end

    # Runs one timer entry inside the current command: its refusals (the
    # state table's), then perform. A refused timer writes nothing. Returns
    # whether it ran.
    def apply(ctx, entry)
      entry.load(ctx)
      return false if Transitions::Precedence.first(entry.refusals(ctx))

      Transitions::Gate.call(ctx, entry)
      entry.perform(ctx)
      true
    end

    # The tasks a command touches: the one its params name (directly or
    # through a review) and those whose task or review the calling seat
    # holds. In id order, so two timers in one command come in a fixed
    # order.
    def due_candidates(ctx)
      workspace_id = ctx.workspace.id
      ids = target_ids(ctx.request.params)
      return [] if ids.empty? && ctx.request.caller_kind != "seat"

      task_ids = ids.empty? ? [] : ids + Review.where(workspace_id: workspace_id, id: ids).pluck(:task_id)
      scope = Task.where(workspace_id: workspace_id, id: task_ids)
      if ctx.request.caller_kind == "seat"
        seat_id = ctx.request.caller_id
        held_reviews = Review.where(workspace_id: workspace_id, reviewer_seat_id: seat_id, verdict: nil).select(:task_id)
        scope = scope.or(Task.where(workspace_id: workspace_id, holder_seat_id: seat_id))
          .or(Task.where(workspace_id: workspace_id, id: held_reviews))
      end
      scope.order(:id).to_a
    end

    # The open reviews of these tasks whose lease is due at ctx.at.
    def due_reviews_of(ctx, task_ids)
      return [] if task_ids.empty?

      Review.where(workspace_id: ctx.workspace.id, task_id: task_ids, verdict: nil).where.not(reviewer_seat_id: nil)
        .order(:id).to_a.select { |review| Leases.due?(review, ctx.at) }
    end

    # The tasks of a workspace whose builder lease is due at the given
    # time, in a state the timer has a row for, oldest due first.
    def due_tasks(workspace_id, at, from_states, limit:)
      Task.where(workspace_id: workspace_id, state: from_states, lease_time_left_while_paused: nil)
        .where(lease_due_at: ..at).order(:lease_due_at, :id).limit(limit).to_a
    end

    # The open reviews of a workspace whose lease is due at the given time,
    # on a task in a state the timer has a row for, oldest due first.
    def due_reviews(workspace_id, at, from_states, limit:)
      Review.joins("JOIN tasks ON tasks.id = reviews.task_id")
        .where(workspace_id: workspace_id, verdict: nil, lease_time_left_while_paused: nil)
        .where.not(reviewer_seat_id: nil).where(lease_due_at: ..at).where(tasks: { state: from_states })
        .order(:lease_due_at, :id).limit(limit).to_a
    end

    # The time a timer's events carry: its due time, or the latest
    # effective time the task's events already have when that is later, so
    # effective times never go backwards within a task (L120) and no step
    # closes before it opened. In a real run the due time is always the
    # later one: a lease is granted by an event and every command on the
    # task applies its timer first. A test that puts a due time in the
    # past with Scenario#make_due (EN-18) can make it the earlier one.
    def effective_at(task, due_at)
      latest = Event.where(workspace_id: task.workspace_id, task_id: task.id).maximum(:effective_at)
      latest && latest > due_at ? latest : due_at
    end

    def target_ids(params)
      TARGET_PARAMS.filter_map { |name| params[name] }.select { |value| value.is_a?(String) && UUID.match?(value) }.uniq
    end
  end
end
