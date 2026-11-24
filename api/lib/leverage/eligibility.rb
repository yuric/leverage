module Leverage
  # Who may act on what (PRD L456, L544-L548; milestone 2 plan EN-8, EN-15,
  # EN-23; RC-50; milestone 3 plan HD-4, HE-14; milestone 4 plan RD-12,
  # RD-14, RD-50, RD-51): whether a seat may claim, the next task and the
  # next review a seat gets with the reviews claim-next skips, whether a
  # reviewer may take a review, whether a failed review's builder is free,
  # and the refusals that say a seat may not act on a task or a review. It
  # reads and writes nothing else; the claims call it under the workspace
  # lock with the command's time, so what it picks is what they take, and
  # GET /v1/next calls it outside one, at the time it reads.
  #
  # A seat the app runs claims only where its run is placed (HD-4): one of
  # its candidates is available for the work (Candidates, rules 1 to 3) and
  # its run is on the first of them (seats.run_credential_id, HD-3), so
  # every claim records the account that does the work (L667, L690). A seat
  # that connects on its own has no candidates and no run the app places.
  module Eligibility
    PRIORITY_ORDER = Arel.sql("CASE tasks.priority WHEN 'high' THEN 0 WHEN 'normal' THEN 1 ELSE 2 END")
    CLAIM_HOOK = "task.before_claim".freeze

    module_function

    # Whether the seat may claim at all (L545): enabled, not paused, not
    # removed, of the role that claims this kind (a builder a task, a
    # reviewer a review), holding no task or review, with no approved
    # action waiting for it, and, for a seat the app runs, its run on its
    # first available candidate (HD-4).
    #
    # kind - :task or :review.
    def may_claim?(seat, kind, at: Time.current, task: nil)
      return false unless seat && seat.enabled && !seat.paused && seat.removed_at.nil?
      return false unless Roles.acts_as?(seat.role, kind == :review ? "reviewer" : "builder")
      return claim_standing?(seat, task) && momentary?(seat, task, at: at) if task
      return false unless idle_for_claim?(seat, at: at)

      placed_for?(seat, nil, at)
    end

    # Whether the seat is idle enough to take a new claim.
    def idle_for_claim?(seat, at: Time.current)
      !holds_anything?(seat, at: at) && Finishing.waiting_for(seat).empty?
    end

    # Escalation reads standing even when the seat is paused or has work.
    def standing?(seat, task, rank:)
      builder_at_rank?(seat, rank) && !reviewed?(seat, task)
    end

    # A claim also needs the seat and the task to be free now. The gating
    # filter includes projects that reached their budget while the rule is on.
    def momentary?(seat, task, at:, excluded_task_ids: nil)
      return false if seat.paused || !idle_for_claim?(seat, at: at)
      return false if task.holder_seat_id || on_hold?(task) || PendingTransitions.of(task)
      return false if task.project_id && Project.exists?(id: task.project_id, paused: true)
      excluded_task_ids ||= Gating.claimable_filter(seat_id: seat.id, kind: :task).excluded_task_ids
      return false if excluded_task_ids.include?(task.id)

      placed_for?(seat, task, at)
    end

    def claim_standing?(seat, task)
      rank = task.minimum_strength_rank
      return false unless builder_at_rank?(seat, rank)
      return true unless seat.role == "general" && reviewed?(seat, task)

      Seat.where(workspace_id: task.workspace_id, role: Roles.roles_acting_as("builder"), enabled: true,
        removed_at: nil, paused: false).where.not(id: seat.id).none? { |other| standing?(other, task, rank: rank) }
    end

    def builder_at_rank?(seat, rank)
      seat&.enabled && seat.removed_at.nil? && Roles.acts_as?(seat.role, "builder") &&
        (!rank || seat.strength_rank >= rank)
    end

    def reviewed?(seat, task)
      Event.exists?(workspace_id: task.workspace_id, task_id: task.id, type: "review.started",
        actor_kind: "seat", actor_id: seat.id)
    end

    # The Ready task the seat would claim now, or nil: by priority high,
    # normal, low, then the oldest, then the id (EN-23); with no open hold,
    # no minimum strength rank above the seat's, a running project, and not
    # filtered out by gating (RC-19); and, for a seat the app runs, a task
    # it is placed for (HD-4). nil too when the seat may not claim.
    #
    # Before that order comes a task on which the seat has a failed claim
    # check the owner overrode, on the task's current inputs (milestone 4
    # plan RD-14), so the override does what L910 says: the task proceeds
    # on the seat's next request.
    def next_task(seat, at: Time.current)
      return nil unless may_claim?(seat, :task, at: at)

      excluded = Gating.claimable_filter(seat_id: seat.id, kind: :task).excluded_task_ids
      scope = Task.where(workspace_id: seat.workspace_id, state: "ready", holder_seat_id: nil)
        .where.not(id: open_hold_task_ids(seat.workspace_id))
        .where("tasks.minimum_strength_rank IS NULL OR tasks.minimum_strength_rank <= ?", seat.strength_rank)
        .where("tasks.project_id IS NULL OR tasks.project_id NOT IN (SELECT id FROM projects WHERE paused)")
      scope = scope.where.not(id: excluded) unless excluded.empty?
      tasks = scope.order(PRIORITY_ORDER, :created_at, :id).to_a
      overridden = overridden_claim_task_ids(seat, tasks)
      first, rest = tasks.partition { |task| overridden.include?(task.id) }
      (first + rest).find do |task|
        claim_standing?(seat, task) && momentary?(seat, task, at: at, excluded_task_ids: excluded)
      end
    end

    # The open review the seat would claim now, or nil: the oldest
    # (reviews.created_at, then id, EN-23) with no reviewer, on a task In
    # review with no open hold, of the task's current round, that the seat
    # never built (L455, read from task.claimed), that the claim filter
    # does not leave out (RC-50), whose provider the provider rule allows,
    # and, for a seat the app runs, one it is placed for (HD-4). nil too
    # when the seat may not claim.
    #
    # The provider asked about is that of the account the review would run
    # on (milestone 4 plan RD-50, L451): for a seat the app runs, the
    # credential its run is on (SeatRuns.run_credential_id), which is the
    # one the claim records; for a seat that connects on its own, its own.
    def next_review(seat, at: Time.current)
      review_and_skipped(seat, at: at).first
    end

    # What review claim-next does for the seat, as [review, skipped]: the
    # review next_review takes (or nil), and, in claim order, the open
    # reviews before it (all of them when none is taken) that it passed
    # over because the claim filter leaves them out or the provider rule
    # refuses the seat's account: those the provider rule keeps from a seat
    # that is otherwise eligible (L297, RC-50, milestone 4 plan RD-12). A
    # review the seat built, and one it is not placed for, is passed over
    # for another reason and is not among them. [nil, []] when the seat may
    # not claim.
    def review_and_skipped(seat, at: Time.current)
      return [ nil, [] ] unless may_claim?(seat, :review, at: at)

      excluded = Gating.claimable_filter(seat_id: seat.id, kind: :review).excluded_review_ids
      provider = review_provider(seat)
      return [ nil, [] ] if gemini_review?(seat, provider)

      skipped = []
      open_reviews(seat).each do |review|
        if excluded.include?(review.id) || !Gating.provider_allowed?(task_id: review.task_id, provider: provider)
          skipped << review
        elsif placed_for?(seat, review, at)
          return [ review, skipped ]
        end
      end
      [ nil, skipped ]
    end

    # Whether the seat may take the review now, whatever it holds and
    # whatever hold is on the task (milestone 4 plan RD-51, SM-42): a
    # reviewer seat, enabled, not paused and not removed, that never built
    # the task (L455), whose review would run on an account the provider
    # rule allows. For a seat the app runs that is the account its run
    # belongs on (Candidates rule 2, HD-4: its first available candidate),
    # which must also be the first one rule 3 keeps for the review: a seat
    # whose accounts are all limited or signed out has none, and one whose
    # run belongs on an account of a provider that built the task is never
    # placed for it. A seat that connects on its own reviews on its own
    # provider. The rule's answer is Gating's (provider_allowed?, HE-41),
    # always yes while the rule is off.
    def may_review?(seat, review, at: Time.current)
      return false unless seat && Roles.acts_as?(seat.role, "reviewer") && seat.enabled && !seat.paused && seat.removed_at.nil?
      return false if built_by(seat).where(task_id: review.task_id).exists?
      return Gating.provider_allowed?(task_id: review.task_id, provider: seat.provider) unless seat.credential_id

      account = Candidates.first_available(seat, nil, at)
      !account.nil? && !gemini_review?(seat, account.provider) && Gating.provider_allowed?(task_id: review.task_id, provider: account.provider) &&
        Candidates.first_available(seat, review, at)&.id == account.id
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
      return false if holds_anything?(seat, at: at)

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
      codes << "forbidden" unless Roles.acts_as?(seat.role, role)
      codes
    end

    # The same for a reviewer and the review it acts on: it holds a review
    # while it is the review's reviewer and no verdict is given (DB-20).
    def review_refusals(review, seat)
      codes = []
      codes << lost_review_refusal(review, seat) unless review.reviewer_seat_id == seat.id && review.verdict.nil?
      codes << "forbidden" unless Roles.acts_as?(seat.role, "reviewer")
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

    def holds_anything?(seat, at: Time.current)
      tasks = Task.where(workspace_id: seat.workspace_id, holder_seat_id: seat.id)
      reviews = Review.where(workspace_id: seat.workspace_id, reviewer_seat_id: seat.id, verdict: nil)
      return tasks.exists? || reviews.exists? unless seat.role == "general"

      live = "lease_due_at IS NULL OR lease_due_at > ?"
      tasks.where(live, at).exists? || reviews.where(live, at).exists? || Jobs.held(seat, at).present?
    end

    def gemini_review?(seat, provider)
      seat.role == "general" && seat.credential_id.present? && provider == "gemini"
    end

    # HD-4: a seat that connects on its own always; a seat the app runs
    # when its run is on its first candidate available at at for the work
    # (nil asks rule 2 only). Its run is on the credential its token was
    # issued for, or its own for a token issued before that was recorded
    # (SeatRuns.run_credential_id, HD-3). Public: a provisional claim asks
    # it again when its check settles (Entries::Claim).
    def placed_for?(seat, work, at)
      return true unless seat.credential_id

      first = Candidates.first_available(seat, work, at)
      !first.nil? && SeatRuns.run_credential_id(seat) == first.id
    end

    # The open reviews a reviewer seat may be offered, in claim order
    # (EN-23): no reviewer and no verdict, of the task's current round, on a
    # task In review with no open hold, that the seat never built (L455).
    def open_reviews(seat)
      Review.joins("JOIN tasks ON tasks.id = reviews.task_id AND tasks.round = reviews.round")
        .where(workspace_id: seat.workspace_id, verdict: nil, reviewer_seat_id: nil, tasks: { state: "in_review" })
        .where.not(task_id: open_hold_task_ids(seat.workspace_id))
        .where.not(task_id: built_by(seat))
        .order("reviews.created_at", "reviews.id")
    end

    # RD-50: the provider of the account the seat's review would run on now.
    def review_provider(seat)
      return seat.provider unless seat.credential_id

      Credential.find_by(id: SeatRuns.run_credential_id(seat), workspace_id: seat.workspace_id)&.provider || seat.provider
    end

    # RD-14: the ids of those tasks on which the seat has a failed
    # task.before_claim check of the task's current round that the owner
    # overrode, whose input hash is that of the task's current contract
    # version and this seat (hooks.json: the two inputs the hook hashes).
    def overridden_claim_task_ids(seat, tasks)
      return [] if tasks.empty?

      by_id = tasks.index_by(&:id)
      RuleCheck.where(workspace_id: seat.workspace_id, task_id: by_id.keys, hook: CLAIM_HOOK, subject_kind: "seat",
        subject_id: seat.id, result: "failed").where.not(overridden_at: nil)
        .pluck(:task_id, :round, :input_hash)
        .select { |task_id, round, input_hash| round == by_id[task_id].round && input_hash == claim_hash(by_id[task_id], seat) }
        .map(&:first)
    end

    def claim_hash(task, seat)
      Gating.input_hash(hook: CLAIM_HOOK, inputs: HookInputs.for(hook: CLAIM_HOOK, task: task, params: {}, seat: seat))
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

    private_class_method :lost_task_refusal, :lost_review_refusal, :open_reviews, :builder_at_rank?, :reviewed?, :gemini_review?,
      :review_provider, :overridden_claim_task_ids, :claim_hash, :open_hold_task_ids, :built_by, :held_when_cancelled?,
      :reviewed_when_cancelled?
  end
end
