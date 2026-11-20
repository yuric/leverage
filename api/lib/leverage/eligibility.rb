module Leverage
  # Who may act on what (PRD L456, L544-L548; milestone 2 plan EN-8, EN-15,
  # EN-23; RC-50; milestone 3 plan HD-4, HE-14): whether a seat may claim,
  # the next task and the next review a seat gets, whether a failed review's
  # builder is free, and the refusals that say a seat may not act on a task
  # or a review. It reads and writes nothing else; the claims call it under
  # the workspace lock with the command's time, so what it picks is what
  # they take, and GET /v1/next calls it outside one, at the time it reads.
  #
  # A seat the app runs claims only where its run is placed (HD-4): one of
  # its candidates is available for the work (Candidates, rules 1 to 3) and
  # its run is on the first of them (seats.run_credential_id, HD-3), so
  # every claim records the account that does the work (L667, L690). A seat
  # that connects on its own has no candidates and no run the app places.
  module Eligibility
    PRIORITY_ORDER = Arel.sql("CASE tasks.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END")

    module_function

    # Whether the seat may claim at all (L545): enabled, not paused, not
    # removed, of the role that claims this kind (a builder a task, a
    # reviewer a review), holding no task and no review, and, for a seat
    # the app runs, its run on its first available candidate (HD-4, which
    # takes the place of EN-8's own-credential test).
    #
    # kind - :task or :review.
    def may_claim?(seat, kind, at: Time.current)
      return false unless seat && seat.enabled && !seat.paused && seat.removed_at.nil?
      return false unless seat.role == (kind == :review ? "reviewer" : "builder")
      return false if holds_anything?(seat)

      placed_for?(seat, nil, at)
    end

    # The Ready task the seat would claim now, or nil: by priority high,
    # normal, low, then the oldest, then the id (EN-23); with no open hold,
    # no minimum strength rank above the seat's, a running project, and not
    # filtered out by gating (RC-19); and, for a seat the app runs, a task
    # it is placed for (HD-4). nil too when the seat may not claim.
    def next_task(seat, at: Time.current)
      return nil unless may_claim?(seat, :task, at: at)

      excluded = Gating.claimable_filter(seat_id: seat.id, kind: :task).excluded_task_ids
      scope = Task.where(workspace_id: seat.workspace_id, state: "ready", holder_seat_id: nil)
        .where.not(id: open_hold_task_ids(seat.workspace_id))
        .where("tasks.minimum_strength_rank IS NULL OR tasks.minimum_strength_rank <= ?", seat.strength_rank)
        .where("tasks.project_id IS NULL OR tasks.project_id NOT IN (SELECT id FROM projects WHERE paused)")
      scope = scope.where.not(id: excluded) unless excluded.empty?
      scope.order(PRIORITY_ORDER, :created_at, :id).find { |task| placed_for?(seat, task, at) }
    end

    # The open review the seat would claim now, or nil: the oldest
    # (reviews.created_at, then id, EN-23) with no reviewer, on a task In
    # review with no open hold, of the task's current round, that the seat
    # never built (L455, read from task.claimed), whose provider gating
    # allows, not filtered out by gating (RC-50), and, for a seat the app
    # runs, one it is placed for (HD-4). nil too when the seat may not
    # claim.
    def next_review(seat, at: Time.current)
      return nil unless may_claim?(seat, :review, at: at)

      excluded = Gating.claimable_filter(seat_id: seat.id, kind: :review).excluded_review_ids
      scope = Review.joins("JOIN tasks ON tasks.id = reviews.task_id AND tasks.round = reviews.round")
        .where(workspace_id: seat.workspace_id, verdict: nil, reviewer_seat_id: nil, tasks: { state: "in_review" })
        .where.not(task_id: open_hold_task_ids(seat.workspace_id))
        .where.not(task_id: built_by(seat))
      scope = scope.where.not(id: excluded) unless excluded.empty?
      scope.order("reviews.created_at", "reviews.id").find do |review|
        Gating.provider_allowed?(task_id: review.task_id, provider: seat.provider) && placed_for?(seat, review, at)
      end
    end

    # Whether the failed review's previous builder is free (state machine
    # guard builder_free): it holds nothing and is enabled, not paused and
    # not removed, and, for a seat the app runs, one of its candidates is
    # available for the task at at (HE-14); its run need not be on it yet:
    # the fresh lease starts on the first of them and the run follows
    # (HD-1). It reads the rows: FailReview first ends the builder's leases
    # that are past their due time (Timers.apply_held_by), as the claims end
    # the leases in their way (Timers.apply_claimable).
    def builder_free?(seat, task = nil, at: Time.current)
      return false unless seat&.enabled && !seat.paused && seat.removed_at.nil?
      return false if holds_anything?(seat)

      seat.credential_id.nil? || !Candidates.first_available(seat, task, at).nil?
    end

    # The refusals that keep a seat from acting on a task as its holder, in
    # precedence order: lease_expired when its latest lease ended at its
    # due time (EN-15), task_cancelled when it held the task when it was
    # cancelled (L207), else not_holder when it does not hold the task now;
    # and forbidden when it is not of the role (L548).
    def task_refusals(task, seat, role: "builder")
      codes = []
      codes << lost_task_refusal(task, seat) unless task.holder_seat_id == seat.id
      codes << "forbidden" unless seat.role == role
      codes
    end

    # The same for a reviewer and the review it acts on: it holds a review
    # while it is the review's reviewer and no verdict is given (DB-20).
    def review_refusals(review, seat)
      codes = []
      codes << lost_review_refusal(review, seat) unless review.reviewer_seat_id == seat.id && review.verdict.nil?
      codes << "forbidden" unless seat.role == "reviewer"
      codes
    end

    # Whether any hold is open on the task (L174).
    def on_hold?(task)
      Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil).exists?
    end

    def lost_task_refusal(task, seat)
      return "lease_expired" if Leases.ended_by_expiry?(task, seat)
      return "task_cancelled" if held_when_cancelled?(task, seat)

      "not_holder"
    end

    def lost_review_refusal(review, seat)
      return "lease_expired" if review.verdict.nil? && Leases.ended_by_expiry?(review, seat)
      return "task_cancelled" if reviewed_when_cancelled?(review, seat)

      "not_holder"
    end

    def holds_anything?(seat)
      Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id).exists? ||
        Review.where(workspace_id: seat.workspace_id, reviewer_seat_id: seat.id, verdict: nil).exists?
    end

    # HD-4: a seat that connects on its own always; a seat the app runs
    # when its run is on its first candidate available at at for the work
    # (nil asks rule 2 only). Its run is on the credential its token was
    # issued for, or its own for a token issued before that was recorded
    # (SeatRuns.run_credential_id, HD-3).
    def placed_for?(seat, work, at)
      return true unless seat.credential_id

      first = Candidates.first_available(seat, work, at)
      !first.nil? && SeatRuns.run_credential_id(seat) == first.id
    end

    def open_hold_task_ids(workspace_id)
      Hold.where(workspace_id: workspace_id, closed_at: nil).select(:task_id)
    end

    # The tasks the seat ever had a builder lease on (L455).
    def built_by(seat)
      Event.where(workspace_id: seat.workspace_id, type: Leases::BUILDER_GRANT)
        .where("payload ->> 'seat_id' = ?", seat.id).select(:task_id)
    end

    # Whether the seat held the task's builder lease when it was cancelled:
    # the lease granted last before task.cancelled, not ended by a release,
    # an expiry or a submit.
    def held_when_cancelled?(task, seat)
      return false unless task.state == "cancelled"

      holder = nil
      Event.where(workspace_id: task.workspace_id, task_id: task.id).order(:seq).each do |event|
        grantee = Leases.builder_grantee(event)
        if grantee
          holder = grantee
        elsif %w[task.released task.lease_expired task.submitted].include?(event.type)
          holder = nil
        elsif event.type == "task.cancelled"
          return holder == seat.id
        end
      end
      false
    end

    # Whether the seat held the review when its task was cancelled.
    def reviewed_when_cancelled?(review, seat)
      holder = nil
      Event.where(workspace_id: review.workspace_id, task_id: review.task_id).order(:seq).each do |event|
        if event.subject_kind == "review" && event.subject_id == review.id
          case event.type
          when "review.started" then holder = event.actor_id
          when "review.released", "review.lease_expired", "review.passed", "review.failed" then holder = nil
          end
        elsif event.type == "task.cancelled"
          return holder == seat.id
        end
      end
      false
    end

    private_class_method :lost_task_refusal, :lost_review_refusal, :holds_anything?, :placed_for?, :open_hold_task_ids, :built_by,
      :held_when_cancelled?, :reviewed_when_cancelled?
  end
end
