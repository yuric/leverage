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

    # The Needs you item a sign-out opens or that its verification resolves
    # (needs_you.json).
    ACCOUNT_SIGNED_OUT = "account_signed_out".freeze

    module_function

    # Rule 5: marks the stopped credential and writes the first event,
    # credential.limit_reached or credential.signed_out, with the credential
    # as subject, on the work's task. A limit: limited_since is the
    # command's time, and limited_until the reset time when it is after
    # observed_at (HE-32), never earlier than a later reset already stored
    # (HE-22); a limit with no reset time has none. A sign-out: state
    # signed_out. The seat's run is recorded as ended (HD-10).
    #
    # kind        - "limit" or "signed_out".
    # task:, review: - the work the run was doing: the task, or the review
    #               (whose task the event is written on).
    # window:, reset_at:, observed_at: - a limit's report, the times as Time.
    #
    # Returns the first Event.
    def interrupt(ctx, credential:, seat:, kind:, task: nil, review: nil, window: nil, reset_at: nil, observed_at: nil)
      on = task || Task.find(review.task_id)
      payload = { seat_id: seat.id, review_id: review&.id, job_id: nil }
      if kind == "limit"
        reset = reset_at if reset_at && observed_at && reset_at > observed_at
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

    # Rule 6: with a next candidate (Candidates.next_after), switch; with
    # none, a task's hold or a review's release (review.released caused by
    # cause). The hold is credential_signed_out when any candidate is
    # signed out, naming the first in the seat's order (HE-12), else
    # credential_limit naming the candidate that resets first, or the
    # stopped credential when none has a reset time (HE-13). Its item opens
    # only when the owner must act: the reason is credential_signed_out or
    # no candidate has a reset time, and no candidate is available, which
    # rule 4 leaves only between the seat's own and the stopped one; such
    # a hold is due at once (rule 8, HE-4) and needs nobody.
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
        SeatRuns.release_review(ctx, review, cause_id: cause.id)
      else
        hold(ctx, seat, task, stopped, cause)
      end
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

    def hold(ctx, seat, task, stopped, cause)
      signed_out = Candidates.for(seat).find { |credential| credential.state == "signed_out" }
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
    # "Account signed out" item naming the verified account is resolved.
    def look_again(ctx, open, task, seat, cause:, verified:, choice:)
      to = Candidates.first_available(seat, task, ctx.at)
      if to
        go_on(ctx, open, task, seat, to, cause: cause&.id, choice: choice, **ctx_actor(ctx))
      elsif verified
        InboxItem.where(hold_id: open.id, state: "open", kind: ACCOUNT_SIGNED_OUT, credential_id: verified.id)
          .order(:opened_at).each { |item| resolve(ctx, item, task, choice) }
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
    # that the sign-out of signed_out, one of its seat's candidates, has
    # left with no due time and no open item. No hold event: the hold keeps
    # its reason, and the lease keeps running.
    def open_signed_out_item(ctx, open, task, seat, signed_out, cause)
      return unless open.reason == "credential_limit"
      return unless Candidates.for(seat).any? { |credential| credential.id == signed_out.id }
      return if InboxItem.where(hold_id: open.id, state: "open").exists?

      last = Event.where(workspace_id: task.workspace_id, task_id: task.id).maximum(:effective_at) || ctx.at
      return if Candidates.due_at(seat, task, last)

      choices = Holds.needs_you_item("credential_signed_out").fetch("choices").map { |entry| entry.fetch("choice") }
      item = InboxItem.create!(workspace_id: task.workspace_id, kind: ACCOUNT_SIGNED_OUT, about_kind: "task",
        about_id: task.id, hold_id: open.id, credential_id: signed_out.id, facts: { credential_id: signed_out.id },
        opened_at: ctx.at, choices: choices)
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

    def switch_as(ctx, seat:, to:, from:, cause:, task: nil, review: nil, **as)
      on = task || Task.find(review.task_id)
      switched = ctx.emit("credential.switched", task: on, subject: to, cause_id: cause&.id, **as,
        payload: { from_credential_id: from&.id, model: Candidates.model_for(seat, to), seat_id: seat.id,
                   review_id: review&.id, job_id: nil })
      (review || task).update!(credential_id: to.id)
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

    private_class_method :hold, :each_open_hold, :look_again, :go_on, :open_signed_out_item, :resolve, :switch_as,
      :app_actor, :ctx_actor
  end
end
