module Leverage
  # "No reviewer is eligible" (PRD L201, L451, L938; contract decision SM-42;
  # milestone 4 plan RD-50, RD-51): the Needs you item of a task whose
  # review waits while no connected reviewer may take it.
  #
  # The item is open exactly while the provider rule ("A different provider
  # reviews every task", key different_provider_review) is on and not
  # removed, the task's review of its current round waits for a reviewer,
  # and no seat may take it now (Eligibility.may_review?: a reviewer seat,
  # enabled, not paused, not removed, that never built the task, whose
  # review would run on an account the rule allows; a seat whose accounts
  # are all limited or signed out has none). With the rule off no item
  # opens, and an open one resolves: its facts name the rule and its
  # second choice turns it off (RD-51). Holds and what a seat already holds
  # do not count: neither Hold nor a verdict is a command that re-evaluates
  # it.
  #
  # It runs on what a command changed, after its perform (Transitions),
  # and right after each review lease a timer ends:
  #
  # - for the task of each task.submitted and review.released the command
  #   wrote (SM-42: the review waits), whichever command wrote it (a
  #   pending submit completed by a job result), and for the task of each
  #   review.lease_expired, at once, by the review lease timer that
  #   writes it (Entries::ReviewLeaseExpiry), wherever that timer runs: as
  #   the sweep's command, or inside another command, before its
  #   refusals (Timers.apply_due) or in its load (Timers.apply_claimable,
  #   Timers.apply_held_by). Its events carry that event's key, effective
  #   time and actor (the app for a seat's event) and name it as their
  #   cause, as the hold events of Holds.close_seat_bound do;
  # - for every waiting task, after a command of REEVALUATED_BY whose rows
  #   have no task state (a seat, rule or account change), with the
  #   command's own key, as its caller (the app for a seat), and no cause;
  #   resolved with the item's choice whose operation runs the command
  #   (connect_seat, or turn_rule_off for disable_rule), else none.
  #
  # The reviewer_eligibility timer is one of those commands: the sweep
  # applies it for what no command writes, such as a credential reset.
  module ReviewerEligibility
    ITEM = "no_reviewer_eligible".freeze
    PROVIDER_RULE = "different_provider_review".freeze

    # The commands whose state rows carry the item's side events (SM-42;
    # state_machine.json): the one list of commands after which it runs.
    REEVALUATED_BY = %w[
      submit release_review review_lease_expiry report_limit report_signed_out
      connect_seat change_seat pause_seat resume_seat remove_seat report_run_stopped report_request_result
      install_shipped_rules enable_rule disable_rule save_rule revert_rule remove_rule reviewer_eligibility
    ].freeze

    # Those of them whose rows are a task's: they re-evaluate the task of
    # the waiting event they write, and nothing else.
    TASK_ROWS = %w[submit release_review review_lease_expiry report_limit report_signed_out].freeze

    # The events after which a review waits for a reviewer (SM-42).
    WAITING = %w[task.submitted review.released review.lease_expired].freeze
    # Those after_command reads in what a command wrote. The review lease
    # timer has written the item of each review.lease_expired already,
    # right after it: read again after perform, the item would come after
    # the command's own events with the lease's earlier effective time.
    AFTER_PERFORM = (WAITING - %w[review.lease_expired]).freeze

    module_function

    # Called by Transitions after a command's perform, with its entry.
    # Returns the Events it wrote.
    def after_command(ctx, entry)
      return [] if ctx.workspace.nil?

      written = after_events(ctx)
      command = entry.command.to_s
      written += reevaluate(ctx) if REEVALUATED_BY.include?(command) && !TASK_ROWS.include?(command)
      written
    end

    # The tasks of the task.submitted and review.released events the
    # command wrote so far, each re-evaluated with that event as its cause.
    # Returns the Events it wrote.
    def after_events(ctx)
      return [] if ctx.workspace.nil?

      causes = ctx.events.select { |event| AFTER_PERFORM.include?(event.type) && event.task_id }
        .group_by(&:task_id).transform_values(&:last)
      causes.flat_map { |task_id, cause| reevaluate(ctx, task_ids: [ task_id ], cause: cause) }
    end

    # Opens or resolves the item for each task whose review waits for a
    # reviewer and each task with an open item, or only those of task_ids.
    #
    # cause: - the Event that made the review wait, or nil: what the events
    #          carry (above), and the time availability is read at.
    #
    # Returns the Events it wrote.
    def reevaluate(ctx, task_ids: nil, cause: nil)
      workspace_id = ctx.workspace.id
      rule = Rule.find_by(workspace_id: workspace_id, key: PROVIDER_RULE, enabled: true, removed_at: nil)
      waiting = waiting_reviews(workspace_id, task_ids)
      items = open_items(workspace_id, task_ids)
      return [] if items.empty? && (rule.nil? || waiting.empty?)

      at = cause&.effective_at || ctx.effective_at
      seats = rule ? reviewers(workspace_id) : []
      (waiting.keys | items.keys).flat_map do |task_id|
        review = waiting[task_id]
        nobody = rule && review && seats.none? { |seat| Eligibility.may_review?(seat, review, at: at) }
        wanted = nobody ? review : nil
        item = items[task_id]
        events = []
        events << resolve_item(ctx, item, cause) if item && item.facts["review_id"] != wanted&.id
        events << open_item(ctx, wanted, rule, cause) if wanted && item&.facts&.fetch("review_id") != wanted.id
        events
      end
    end

    # The review of its current round each task In review waits on, by
    # task id, in claim order.
    def waiting_reviews(workspace_id, task_ids)
      scope = Review.joins("JOIN tasks ON tasks.id = reviews.task_id AND tasks.round = reviews.round")
        .where(workspace_id: workspace_id, verdict: nil, reviewer_seat_id: nil, tasks: { state: "in_review" })
      scope = scope.where(task_id: task_ids) if task_ids
      scope.order("reviews.created_at", "reviews.id").to_a.index_by(&:task_id)
    end

    def open_items(workspace_id, task_ids)
      scope = InboxItem.where(workspace_id: workspace_id, kind: ITEM, about_kind: "task", state: "open")
      scope = scope.where(about_id: task_ids) if task_ids
      scope.order(:opened_at, :id).to_a.index_by(&:about_id)
    end

    def reviewers(workspace_id)
      Seat.where(workspace_id: workspace_id, role: "reviewer", enabled: true, paused: false, removed_at: nil)
        .order(:created_at, :id).to_a
    end

    def open_item(ctx, review, rule, cause)
      task = Task.find(review.task_id)
      as = as(ctx, cause)
      item = InboxItem.create!(workspace_id: task.workspace_id, kind: ITEM, about_kind: "task", about_id: task.id,
        facts: { "review_id" => review.id, "rule_id" => rule.id }, opened_at: ctx.at,
        choices: needs_you.fetch("choices").map { |choice| choice.fetch("choice") })
      ctx.emit("inbox.opened", task: task, subject: item, **as, payload: { kind: ITEM })
    end

    def resolve_item(ctx, item, cause)
      task = Task.find(item.about_id)
      as = as(ctx, cause)
      item.update!(state: "resolved", resolved_by_kind: as[:actor_kind], resolved_by_id: as[:actor_id], resolved_at: ctx.at)
      ctx.emit("inbox.resolved", task: task, subject: item, **as, payload: { choice: (choice(ctx) unless cause) })
    end

    # Who the events are written as (milestone 4 plan WP0T's choice 5, as
    # traces 02 and 19 show): the cause's actor and key, or the command's,
    # and the app in a seat's place.
    def as(ctx, cause)
      kind, id = cause ? [ cause.actor_kind, cause.actor_id ] : ctx.actor
      kind, id = "app", nil if kind == "seat"
      fields = { actor_kind: kind, actor_id: id, cause_id: cause&.id, command_id: cause ? cause.command_id : ctx.request.key }
      fields[:effective_at] = cause.effective_at if cause
      fields
    end

    # The item's choice whose operation runs the command, or nil.
    def choice(ctx)
      operations = Contract.registry.fetch("operations").to_h { |op| [ op.fetch("operation_id"), op.fetch("commands") ] }
      needs_you.fetch("choices")
        .find { |entry| operations.fetch(entry.fetch("operation_id"), []).include?(ctx.request.command) }
        &.fetch("choice")
    end

    def needs_you
      Contract.needs_you.fetch("items").find { |entry| entry.fetch("item") == ITEM }
    end

    private_class_method :waiting_reviews, :open_items, :reviewers, :open_item, :resolve_item, :as, :choice, :needs_you
  end
end
