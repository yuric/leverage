module Leverage
  # What happens to a piece of work when its credential stops or becomes
  # available (PRD L650-L703; milestone 3 plan §2.1 rules 5 to 8, HE-2,
  # HE-4, HE-9 to HE-13, HE-21, HE-29, HD-1). The only caller of Holds for
  # the two credential reasons. Every event goes through ctx.emit, inside
  # the command's transaction; which accounts are candidates, available or
  # next is Candidates'.
  #
  # Who writes the events (traces 11 to 14): inside a report or a request
  # result the helper's, as the app with the helper's id (ctx.actor); inside
  # a seat's or the owner's command a credential.switched is the app's, with
  # no id (L690: "with the app as actor"); the credential timer's are the
  # app's with no key, at its due time.
  module Handoff
    # How many open credential holds reevaluate reads at a time (HE-10).
    BATCH = 100

    # The hold reasons a credential stop opens (registry hold_reasons).
    CREDENTIAL_REASONS = %w[credential_limit credential_signed_out].freeze

    # How far after observed_at a reported reset time may be, by the window
    # it names (registry limit_windows), with a margin: a reset further off
    # is no reset the provider gave, and is stored as none, which the next
    # Verify clears (HE-2). A report that names no window takes the longest.
    RESET_BOUNDS = {
      "five_hour" => 6 * 3600, "weekly" => 8 * 86_400, "per_model" => 8 * 86_400, "spend" => 32 * 86_400
    }.freeze

    # The Needs you item a sign-out opens or that its verification resolves
    # (needs_you.json).
    ACCOUNT_SIGNED_OUT = "account_signed_out".freeze
    LIMIT_WITH_NO_RESET = "limit_with_no_reset_time".freeze
    HANDOFF_ORDER_CHANGES = %w[reorder_credentials remove_credential].freeze

    module_function

    # Rule 5: marks the stopped credential and writes the first event,
    # credential.limit_reached or credential.signed_out, with the credential
    # as subject, on the work's task. A limit: limited_since is the
    # command's time, and limited_until the reset time when it is after
    # observed_at (HE-32) and no further after it than the window can last
    # (RESET_BOUNDS), never earlier than a later reset already stored
    # (HE-22); a limit with no reset time has none. A sign-out: state
    # signed_out. The seat's run is recorded as ended (HD-10).
    #
    # kind        - "limit" or "signed_out".
    # task:, review:, job: - the work the run was doing: the task, the
    #               review or the job (the event is written on the review's
    #               or the job's task, milestone 4 plan RD-40).
    # window:, reset_at:, observed_at: - a limit's report, the times as Time.
    #
    # Returns the first Event.
    def interrupt(ctx, credential:, seat:, kind:, task: nil, review: nil, job: nil, window: nil, reset_at: nil,
                  observed_at: nil)
      on = task || work_task(review || job)
      payload = { seat_id: seat.id, review_id: review&.id, job_id: job&.id }
      if kind == "limit"
        reset = reset_at if plausible_reset?(window, reset_at, observed_at)
        stored = credential.limited_until
        credential.update!(limited_since: ctx.at, limited_until: reset && stored && stored > reset ? stored : reset)
        first = ctx.emit("credential.limit_reached", task: on, subject: credential,
          payload: payload.merge(window: window, reset_at: reset&.utc&.iso8601(6)))
      else
        credential.update!(state: "signed_out")
        first = ctx.emit("credential.signed_out", task: on, subject: credential, payload: payload)
      end
      SeatRuns.ended_by_interruption(seat, kind)
      first
    end

    # Whether reset_at is after observed_at and within the window's bound.
    def plausible_reset?(window, reset_at, observed_at)
      return false unless reset_at && observed_at && reset_at > observed_at

      reset_at - observed_at <= RESET_BOUNDS.fetch(window, RESET_BOUNDS.values.max)
    end

    # Rule 6: with a next candidate (Candidates.next_after), switch; with
    # none, a task's hold or a review's release (review.released caused by
    # cause). The hold is credential_signed_out when a candidate that rule
    # 3 keeps for the task is signed out, naming the first in the seat's
    # order (HE-12; one the task passes over could not end the hold), else
    # credential_limit naming the candidate that resets first, or the
    # stopped credential when none has a reset time (HE-13). Its item opens
    # only when the owner must act: the reason is credential_signed_out or
    # no candidate has a reset time, and no candidate is available, which
    # rule 4 leaves only between the seat's own and the stopped one; such
    # a hold is due at once (rule 8, HE-4) and needs nobody.
    #
    # A review released here loses a pass that waits on a model check: the
    # reviewer's pending transition is cancelled first, with invalid_state
    # (PendingTransitions.cancel, milestone 4 plan §2.1 rule 11, §0.1 fact
    # 28), before review.released is written.
    #
    # stopped - the Credential that stopped, already marked.
    # cause   - the first Event, which the events written here name.
    #
    # Returns the Events it wrote.
    def continue_or_hold(ctx, seat:, stopped:, cause:, task: nil, review: nil)
      written = ctx.events.size
      work = review || task
      following = Candidates.next_after(seat, work, stopped, ctx.at)
      if following
        switch(ctx, seat: seat, to: following, from: stopped, cause: cause, task: task, review: review)
      elsif review
        cancel_reviewers_pending(ctx, review)
        SeatRuns.release_review(ctx, review, cause_id: cause.id)
      else
        hold(ctx, seat, task, stopped, cause)
      end
      ctx.events.drop(written)
    end

    # Rule 6 for a job's run (milestone 4 plan RD-40; state_machine.json
    # report_job_limit_or_sign_out): the same order with no rule 3 (a job
    # has no candidates' rule of its own). With a next candidate the job's
    # run switches to it (credential.switched naming the job), the job
    # records it and stays claimed, and the seat's run is moved there; the
    # new run's first claim-next returns the job. With none, nothing more
    # is written: the seat stops claiming jobs and the job runs into its
    # run timeout (no job.requeued).
    #
    # Returns the Events it wrote.
    def continue_job(ctx, seat:, stopped:, cause:, job:)
      written = ctx.events.size
      following = Candidates.next_after(seat, nil, stopped, ctx.at)
      switch_as(ctx, seat: seat, to: following, from: stopped, cause: cause, job: job, **app_actor(ctx)) if following
      ctx.events.drop(written)
    end

    # Rule 7 and HE-10, HE-11: looks again at the open credential holds,
    # oldest first in bounded batches. When a credential was verified or
    # added, or nothing is named (a changed seat), each hold whose holder
    # now has an available candidate closes (hold.closed caused by cause,
    # credential.switched when the first available candidate differs from
    # the one recorded, inbox.resolved, then SeatRuns.ensure_run_on), and an
    # "Account signed out" item naming the verified account is resolved
    # while its hold must still wait. When a credential was found signed
    # out, nothing closes (HE-10): only a credential_limit hold that the
    # sign-out leaves with no due time and no item gets the "Account signed
    # out" item beside it, naming that account (HE-11).
    # Reorder and Remove also open an item for a limit hold left without a
    # due time, and resolve its no-reset item when a due time returns (CR-30).
    #
    # tasks:      - the tasks to look at; nil is every task of the
    #               workspace with an open credential hold.
    # cause:      - the Event the closing events name as their cause.
    # verified:   - a Credential just verified or added, or nil.
    # signed_out: - a Credential just found signed out, or nil.
    # choice:     - the inbox.resolved choice (HE-29), or nil; it is written
    #               only on an item that offers it.
    #
    # Returns the Events it wrote.
    def reevaluate(ctx, tasks: nil, cause: nil, verified: nil, signed_out: nil, choice: nil)
      written = ctx.events.size
      each_open_hold(ctx, tasks) do |open, task, seat|
        if signed_out && !verified
          open_signed_out_item(ctx, open, task, seat, signed_out, cause)
        else
          look_again(ctx, open, task, seat, cause: cause, verified: verified, choice: choice)
        end
      end
      ctx.events.drop(written)
    end

    # Hands a piece of work to another credential: credential.switched
    # (subject to, from_credential_id from, the model of HE-5, the seat and
    # the review), the work's recorded credential becomes to, and
    # SeatRuns.ensure_run_on.
    #
    # Returns the credential.switched Event.
    def switch(ctx, seat:, to:, from:, cause:, task: nil, review: nil)
      switch_as(ctx, seat: seat, to: to, from: from, cause: cause, task: task, review: review, **app_actor(ctx))
    end

    # The credential timer's close (rules 7 and 8, HE-23): the task's
    # credential hold, due at due_at, closes at that time, by the app with
    # no key, and the work goes on on the first candidate available then.
    # A hold whose holder has none available then stays open. Called by
    # Transitions::Entries::CredentialHoldRelease.
    #
    # Returns the Events it wrote.
    def release(ctx, task, due_at:)
      written = ctx.events.size
      open = Holds.open_holds(task).find { |hold| CREDENTIAL_REASONS.include?(hold.reason) }
      seat = open && task.holder_seat_id && Seat.find_by(id: task.holder_seat_id, workspace_id: task.workspace_id)
      to = seat && Candidates.first_available(seat, task, due_at)
      if to
        as = { actor_kind: "app", actor_id: nil, effective_at: Timers.effective_at(task, due_at), command_id: nil }
        go_on(ctx, open, task, seat, to, cause: nil, choice: nil, **as)
      end
      ctx.events.drop(written)
    end

    # --- rule 6 ---------------------------------------------------------------

    # The task a review or a job is about, or nil for a job with none.
    def work_task(work)
      work.task_id && Task.find_by(id: work.task_id, workspace_id: work.workspace_id)
    end

    # Rule 11 of milestone 4's plan: the pass the reviewer of review waits
    # on (the task's pending transition, requested by that seat) is
    # cancelled with invalid_state.
    def cancel_reviewers_pending(ctx, review)
      pending = PendingTransitions.of(work_task(review))
      return unless pending && pending.requester_kind == "seat" && pending.requester_id == review.reviewer_seat_id

      PendingTransitions.cancel(ctx, pending, "invalid_state")
    end

    def hold(ctx, seat, task, stopped, cause)
      signed_out = Candidates.signed_out_for(seat, task)
      resets = Candidates.earliest_reset(seat, task, ctx.at)
      named = signed_out || resets || stopped
      reason = signed_out ? "credential_signed_out" : "credential_limit"
      must_act = (signed_out || resets.nil?) && Candidates.first_available(seat, task, ctx.at).nil?
      actor_kind, actor_id = ctx.actor
      Holds.open(ctx, task: task, reason: reason, cause_id: cause.id, credential_id: named.id, item: must_act,
        facts: { credential_id: named.id }, actor_kind: actor_kind, actor_id: actor_id)
    end

    # --- rule 7 ---------------------------------------------------------------

    # Calls the block with each open credential hold of the tasks (all of
    # the workspace's when tasks is nil), its task and the seat that holds
    # the task, oldest first, BATCH holds at a time. A hold on a task no
    # seat holds is skipped: such a hold closes when the seat loses the
    # task (SM-15).
    def each_open_hold(ctx, tasks)
      scope = Hold.where(workspace_id: ctx.workspace.id, closed_at: nil, reason: CREDENTIAL_REASONS)
      scope = scope.where(task_id: tasks.map(&:id)) if tasks
      after = nil
      loop do
        page = scope.order(:opened_at, :id)
        page = page.where("(holds.opened_at, holds.id) > (?, ?)", *after) if after
        batch = page.limit(BATCH).to_a
        break if batch.empty?

        batch.each do |open|
          task = Task.find(open.task_id)
          seat = task.holder_seat_id && Seat.find_by(id: task.holder_seat_id, workspace_id: task.workspace_id)
          yield open, task, seat if seat && open.reload.closed_at.nil?
        end
        after = [ batch.last.opened_at, batch.last.id ]
      end
    end

    # A hold whose holder has an available candidate closes; else an
    # "Account signed out" item naming the verified account is resolved,
    # and a hold that is then left with no item and no due time gets the
    # item for what still blocks it (open_blocker_item), so it never waits
    # with nothing to end it.
    def look_again(ctx, open, task, seat, cause:, verified:, choice:)
      to = Candidates.first_available(seat, task, ctx.at)
      if to
        go_on(ctx, open, task, seat, to, cause: cause&.id, choice: choice, **ctx_actor(ctx))
      elsif verified
        InboxItem.where(hold_id: open.id, state: "open", kind: ACCOUNT_SIGNED_OUT, credential_id: verified.id)
          .order(:opened_at).each { |item| resolve(ctx, item, task, choice) }
        open_blocker_item(ctx, open, task, seat, cause)
      elsif open.reason == "credential_limit" && HANDOFF_ORDER_CHANGES.include?(ctx.request.command)
        look_at_limit_item(ctx, open, task, seat, cause)
      end
    end

    def look_at_limit_item(ctx, open, task, seat, cause)
      if Candidates.due_at(seat, task, ctx.at)
        InboxItem.where(hold_id: open.id, state: "open", kind: LIMIT_WITH_NO_RESET)
          .order(:opened_at, :id).each { |item| resolve(ctx, item, task, nil) }
      else
        open_blocker_item(ctx, open, task, seat, cause, at: ctx.at)
      end
    end

    # The item a credential hold with no open item and no due time needs:
    # "Account signed out" naming the first signed-out candidate rule 3
    # keeps for the task, else "Limit with no reset time" naming the first
    # such candidate limited with no reset time. No hold event: the hold
    # keeps its reason.
    def open_blocker_item(ctx, open, task, seat, cause, at: nil)
      return if InboxItem.where(hold_id: open.id, state: "open").exists?

      at ||= Event.where(workspace_id: task.workspace_id, task_id: task.id).maximum(:effective_at) || ctx.at
      return if Candidates.due_at(seat, task, at)

      signed_out = Candidates.signed_out_for(seat, task)
      if signed_out
        open_item(ctx, open, task, "credential_signed_out", signed_out, cause)
      elsif (limited = Candidates.limited_with_no_reset_for(seat, task, ctx.at))
        open_item(ctx, open, task, "credential_limit", limited, cause)
      end
    end

    # Closes a credential hold and goes on on to: hold.closed, then
    # credential.switched when to is not the credential recorded for the
    # task, then inbox.resolved for its open item (choice only where the
    # item offers it), then the start on to (HE-21: no run exists while
    # the hold is open).
    def go_on(ctx, open, task, seat, to, cause:, choice:, actor_kind:, actor_id:, effective_at:, command_id:)
      recorded = task.credential_id && Credential.find_by(id: task.credential_id, workspace_id: task.workspace_id)
      offered = choice && InboxItem.where(hold_id: open.id, state: "open").all? { |item| item.choices.include?(choice) }
      Holds.close(ctx, hold: open, task: task, choice: (choice if offered), cause_id: cause, actor_kind: actor_kind,
        actor_id: actor_id, effective_at: effective_at, command_id: command_id) do |closed|
        if recorded&.id == to.id
          SeatRuns.ensure_run_on(ctx, seat, to, task)
        else
          switch_as(ctx, seat: seat, to: to, from: recorded, cause: closed, task: task, actor_kind: "app",
            actor_id: actor_kind == "app" ? actor_id : nil, effective_at: effective_at, command_id: command_id)
        end
      end
    end

    # HE-11: the "Account signed out" item beside a credential_limit hold
    # that the sign-out of signed_out, one of its seat's candidates that
    # rule 3 keeps for the task, has left with no due time and no open
    # item. No hold event: the hold keeps its reason, and the lease keeps
    # running.
    def open_signed_out_item(ctx, open, task, seat, signed_out, cause)
      return unless open.reason == "credential_limit"
      return unless Candidates.kept_for?(seat, signed_out, task)
      return if InboxItem.where(hold_id: open.id, state: "open").exists?

      last = Event.where(workspace_id: task.workspace_id, task_id: task.id).maximum(:effective_at) || ctx.at
      return if Candidates.due_at(seat, task, last)

      open_item(ctx, open, task, "credential_signed_out", signed_out, cause)
    end

    # Opens, beside an open hold, the Needs you item the registry gives
    # reason, naming credential, with inbox.opened caused by cause.
    def open_item(ctx, open, task, reason, credential, cause)
      needs_you = Holds.needs_you_item(reason)
      item = InboxItem.create!(workspace_id: task.workspace_id, kind: needs_you.fetch("item"), about_kind: "task",
        about_id: task.id, hold_id: open.id, credential_id: credential.id, facts: { credential_id: credential.id },
        opened_at: ctx.at, choices: needs_you.fetch("choices").map { |entry| entry.fetch("choice") })
      actor_kind, actor_id = ctx.actor
      ctx.emit("inbox.opened", task: task, subject: item, cause_id: cause&.id, actor_kind: actor_kind, actor_id: actor_id,
        payload: { kind: item.kind })
    end

    # Resolves one Needs you item, with the choice when the item offers it.
    def resolve(ctx, item, task, choice)
      actor_kind, actor_id = ctx.actor
      item.update!(state: "resolved", resolved_by_kind: actor_kind, resolved_by_id: actor_id, resolved_at: ctx.at)
      ctx.emit("inbox.resolved", task: task, subject: item, actor_kind: actor_kind, actor_id: actor_id,
        payload: { choice: (choice if item.choices.include?(choice)) })
    end

    # --- the switch -----------------------------------------------------------

    # The switch itself, for a task, a review or a job (whose run is
    # started with no work named, RD-40).

    def switch_as(ctx, seat:, to:, from:, cause:, task: nil, review: nil, job: nil, **as)
      on = task || work_task(review || job)
      fields = { cause_id: cause&.id, **as }
      fields[:task] = on if on
      switched = ctx.emit("credential.switched", subject: to, **fields,
        payload: { from_credential_id: from&.id, model: Candidates.model_for(seat, to), seat_id: seat.id,
                   review_id: review&.id, job_id: job&.id })
      (review || task || job).update!(credential_id: to.id)
      SeatRuns.ensure_run_on(ctx, seat, to, review || task)
      switched
    end

    # A credential.switched is the app's: with the helper's id inside the
    # helper's command, with none inside a seat's or the owner's.
    def app_actor(ctx)
      kind, id = ctx.actor
      { actor_kind: "app", actor_id: kind == "app" ? id : nil }
    end

    # The command's own actor, time and key, for a close a command makes.
    def ctx_actor(ctx)
      actor_kind, actor_id = ctx.actor
      { actor_kind: actor_kind, actor_id: actor_id, effective_at: ctx.at, command_id: ctx.request.key }
    end

    private_class_method :plausible_reset?, :work_task, :cancel_reviewers_pending, :hold, :each_open_hold, :look_again, :look_at_limit_item, :open_blocker_item, :go_on, :open_signed_out_item,
      :open_item, :resolve, :switch_as, :app_actor, :ctx_actor
  end
end
