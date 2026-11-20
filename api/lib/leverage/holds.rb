module Leverage
  # Holds and their Needs you items (PRD L121, L150-L201; registry
  # hold_reasons, needs_you.json; contract decisions DB-20, DB-23, DB-35).
  #
  # A hold whose reason pauses the lease clock (registry lease_clock
  # "pauses") stops both clocks a task can have: the builder's lease on the
  # task and the reviewer's on its open review, through Leases.pause (a
  # paused lease has no due time and keeps the time it had left, so no
  # timer can end it). When the last pausing hold closes, both clocks run
  # again from the hold's effective close with the time they had left, and when the
  # last hold of any reason closes on a task a seat holds, the seat's next
  # GET /v1/next answers resume (tasks.resume_pending_since, EN-31).
  #
  # The step a hold opens is the step tracker's (Steps.on_event, from
  # hold.opened and hold.closed).
  #
  # Milestone 4 (its plan, WP5; PRD L161-L167, L374-L380, L392): the four
  # rule holds (contract_incomplete, check_error, claim_gate_failed,
  # rerun_limit) open and close here like any other, from the registry's
  # columns, and the caller says whether check_error's task item opens
  # (item:, only while the orchestrator is online, SM-39). A hold and a
  # waiting command (a pending transition, PendingTransitions):
  #
  # - a hold opened on a Ready task with a provisional claim cancels the
  #   claim first, with invalid_state, whatever opens the hold (RD-13,
  #   rule 11); any other pending transition keeps waiting under the hold,
  #   its checks running (L378);
  # - when the last hold on a task lifts, its pending transition is gated
  #   again (PendingTransitions.reenter, trigger hold_lifted, rule 9),
  #   unless the task has ended, the hold is closed by the waiting command
  #   itself while it is performed, or the hold is check_error or
  #   rerun_limit, whose closer acts on the check and gates the transition
  #   with it (override_check, rerun_check, a job's result, a rule turned
  #   off, PendingTransitions.cancel), so it is gated once.
  module Holds
    PAUSES = "pauses".freeze
    # The reasons bound to the seat that holds the task: they close when it
    # loses the task (SM-15; state_machine.json, release's holds_closed).
    SEAT_BOUND = %w[seat_paused credential_limit credential_signed_out].freeze
    # The holds a check of a pending transition opens (L392, RD-45). Whoever
    # closes one acts on that check (Let it through once, Run it again, its
    # result, its rule turned off, the transition cancelled) and gates the
    # transition again itself, with the check as the trigger.
    CHECK_HOLDS = %w[check_error rerun_limit].freeze

    module_function

    # Opens a hold on a task, and its Needs you item when the reason has
    # one, and pauses the task's lease clocks when the reason pauses them.
    # The app opens it unless an actor is named.
    #
    # item: - true (the default) opens the Needs you item the registry
    #         names for the reason; false opens none, for a credential_limit
    #         hold that has a due time (milestone 3 plan §2.1 rule 6, HE-4).
    #
    # Returns the Hold.
    def open(ctx, task:, reason:, cause_id: nil, facts: {}, rule_id: nil, credential_id: nil, actor_kind: "app",
             actor_id: nil, round: task.round, item: true)
      lapse_provisional_claim(ctx, task)
      hold = Hold.create!(workspace_id: task.workspace_id, task_id: task.id, project_id: task.project_id, reason: reason,
        rule_id: rule_id, credential_id: credential_id, opened_at: ctx.at, opened_by_kind: actor_kind,
        opened_by_id: actor_id)
      opened = ctx.emit("hold.opened", task: task, round: round, subject: hold, cause_id: cause_id, actor_kind: actor_kind,
        actor_id: actor_id, payload: { reason: reason, rule_id: rule_id, credential_id: credential_id })
      needs_you = needs_you_item(reason)
      if needs_you && item
        inbox = InboxItem.create!(workspace_id: task.workspace_id, kind: needs_you.fetch("item"), about_kind: "task",
          about_id: task.id, hold_id: hold.id, credential_id: credential_id, facts: facts, opened_at: ctx.at,
          choices: needs_you.fetch("choices").map { |choice| choice.fetch("choice") })
        ctx.emit("inbox.opened", task: task, round: round, subject: inbox, cause_id: opened.id, actor_kind: actor_kind,
          actor_id: actor_id, payload: { kind: inbox.kind })
      end
      leases_of(task).each { |subject| Leases.pause(ctx, subject) } if pauses?(reason)
      hold
    end

    # Closes a hold and resolves its open Needs you item with the owner's
    # choice (nil when it closes on its own; HE-29 says when it is set).
    # The request's caller closes it unless an actor is named. lease_seat_id
    # names the builder the closing gives a fresh lease, if any.
    #
    # effective_at:, command_id: - what the events carry: a timer closes at
    #   its due time with no key (traces 11 and 14). The rows change at
    #   ctx.at, the command's time, as every other row does.
    # A block is given the hold.closed Event before the items are resolved,
    # so a handoff writes credential.switched between them (milestone 3
    # plan §2.1 rule 7).
    #
    # When no pausing hold is left open, the task's lease clocks run again,
    # from effective_at (a timer's close gives the lease no time for the
    # sweep's delay);
    # when no hold at all is left open on a task a seat holds, and the task
    # has not ended in this command (Cancel writes task.cancelled first,
    # EN-30), resume_pending_since is set to the command's time.
    #
    # Returns the Hold.
    def close(ctx, hold:, task:, choice: nil, lease_seat_id: nil, wait_cause: nil, cause_id: nil,
              actor_kind: ctx.actor.first, actor_id: ctx.actor.last, round: task.round, effective_at: ctx.at,
              command_id: ctx.request.key)
      hold.update!(closed_at: ctx.at, closed_by_kind: actor_kind, closed_by_id: actor_id)
      as = { actor_kind: actor_kind, actor_id: actor_id, effective_at: effective_at, command_id: command_id }
      closed = ctx.emit("hold.closed", task: task, round: round, subject: hold, cause_id: cause_id, **as,
        payload: { reason: hold.reason, rule_id: hold.rule_id, credential_id: hold.credential_id,
                   lease_seat_id: lease_seat_id, wait_cause: wait_cause })
      yield closed if block_given?
      InboxItem.where(hold_id: hold.id, state: "open").order(:opened_at).each do |inbox|
        inbox.update!(state: "resolved", resolved_by_kind: actor_kind, resolved_by_id: actor_id, resolved_at: ctx.at)
        ctx.emit("inbox.resolved", task: task, round: round, subject: inbox, **as, payload: { choice: choice })
      end
      remaining = open_holds(task)
      if remaining.none? { |open| pauses?(open.reason) }
        leases_of(task).each { |subject| Leases.restart(ctx, subject, at: effective_at) }
      end
      if remaining.empty?
        mark_resume(ctx, task)
        reenter_pending(ctx, task) unless CHECK_HOLDS.include?(hold.reason)
      end
      hold
    end

    # Closes the holds bound to the seat that held the task, when the seat
    # loses it (SM-15; milestone 3 plan §2.1 rule 7): seat_paused,
    # credential_limit and credential_signed_out, oldest first, each
    # hold.closed then its inbox.resolved, after the event that took the
    # task. They carry that event's actor, effective time and key, and no
    # cause (trace 14, the lease's end). wait_cause goes on the last
    # hold.closed when it leaves the task with no hold, because the
    # wait_ready step opens there (steps.json, derived rule 3); otherwise
    # every hold.closed carries null.
    #
    # cause:      - the task.released or task.lease_expired Event.
    # wait_cause: - the cause of the wait_ready step (Candidates.wait_cause,
    #               HE-35), or nil.
    #
    # Returns the Holds it closed.
    def close_seat_bound(ctx, task, cause:, wait_cause:)
      open = open_holds(task)
      bound = open.select { |hold| SEAT_BOUND.include?(hold.reason) }
      last_of_all = bound.size == open.size
      bound.each_with_index.map do |hold, index|
        close(ctx, hold: hold, task: task, wait_cause: (wait_cause if last_of_all && index == bound.size - 1),
          actor_kind: cause.actor_kind, actor_id: cause.actor_id, effective_at: cause.effective_at,
          command_id: cause.command_id)
      end
    end

    # Pauses a lease just granted on a task, or on its review, while a
    # pausing hold is open (L121, EN-13): it starts paused, with the whole
    # length left. The same as Leases.grant(ctx, subject, paused:
    # Holds.pausing?(task)); a task with no pausing hold keeps its running
    # clock.
    def pause_if_held(ctx, subject)
      task = subject.is_a?(Review) ? Task.find(subject.task_id) : subject
      Leases.pause(ctx, subject) if pausing?(task)
    end

    # The task's open holds, oldest first: in the order their hold.opened
    # events were written (two holds of one command share opened_at).
    def open_holds(task)
      holds = Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil).to_a
      return holds if holds.size < 2

      order = Event.where(workspace_id: task.workspace_id, task_id: task.id, type: "hold.opened",
        subject_id: holds.map(&:id)).pluck(:subject_id, :seq).to_h
      holds.sort_by { |hold| [ order.fetch(hold.id, Float::INFINITY), hold.opened_at ] }
    end

    # The oldest open hold, which names the task's waiting step (L173).
    def oldest_open(task) = open_holds(task).first

    # Whether any hold is open on the task: it blocks the seat commands that
    # move work forward (L174).
    def held?(task)
      Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil).exists?
    end

    # Whether an open hold on the task pauses its lease clocks.
    def pausing?(task)
      Hold.where(workspace_id: task.workspace_id, task_id: task.id, closed_at: nil, reason: pausing_reasons).exists?
    end

    def pauses?(reason) = pausing_reasons.include?(reason)

    def pausing_reasons
      @pausing_reasons ||= Contract.registry.fetch("hold_reasons")
        .select { |entry| entry.fetch("lease_clock") == PAUSES }.map { |entry| entry.fetch("reason") }.freeze
    end

    # The needs_you.json item a hold reason opens, or nil.
    def needs_you_item(reason)
      entry = Contract.registry.fetch("hold_reasons").find { |candidate| candidate.fetch("reason") == reason }
      raise ArgumentError, "unknown hold reason #{reason.inspect}" unless entry

      kind = entry.fetch("needs_you_item")
      kind && Contract.needs_you.fetch("items").find { |item| item.fetch("item") == kind }
    end

    # The rows whose lease clock a hold on the task stops: the task (the
    # builder's lease) and its reviews still without a verdict (DB-20),
    # read again, so the caller's Task is not changed under it.
    def leases_of(task)
      [ Task.find(task.id) ] + Review.where(workspace_id: task.workspace_id, task_id: task.id, verdict: nil).to_a
    end

    # A provisional claim's reservation lapses when a hold opens (L378,
    # RD-13): its pending claim is cancelled with invalid_state before the
    # hold is written (rule 11).
    def lapse_provisional_claim(ctx, task)
      pending = PendingTransitions.of(task)
      PendingTransitions.cancel(ctx, pending, "invalid_state") if pending&.command == "claim"
    end

    # The last hold lifted: the task's pending transition, if any, is gated
    # again (L378, rule 9), once: not when that hold is one of its checks'
    # (CHECK_HOLDS, whose closer gates it), not on a task that has ended
    # (Cancel closes its holds after withdrawing what waited, EN-30), and
    # not inside the waiting command itself while it is performed (its key
    # is the request's, Context#as_requester).
    def reenter_pending(ctx, task)
      return if ended?(ctx, Task.find(task.id))

      pending = PendingTransitions.of(task)
      return if pending.nil? || pending.command_key == ctx.request.key

      PendingTransitions.reenter(ctx, pending, Gating::Trigger.new(kind: :hold_lifted, rule_check_id: nil))
    end

    def ended?(ctx, task)
      %w[done cancelled].include?(task.state) ||
        ctx.events.any? { |event| event.task_id == task.id && Steps::TERMINAL.include?(event.type) }
    end

    def mark_resume(ctx, task)
      task = Task.find(task.id)
      return unless task.holder_seat_id
      return if ended?(ctx, task)

      task.update!(resume_pending_since: ctx.at)
    end
  end
end
