module Leverage
  # The step tracker (PRD, Steps and timing, L269-L306; steps.json): it opens
  # and closes a task's steps from the events EventLog appends, in the same
  # call, so the steps commit with the events (L271).
  #
  # It reads only the log, the task's open step, the task's criteria (their
  # kinds) and a claimed job's kind, which never change, and never a row an
  # entry changes, so the order in which an
  # entry updates its rows and emits its events does not matter, and a
  # replay of the log can drive it the same way. Which criteria a task has
  # as of an event is read from the log too (task.contract_changed's added
  # and removed ids): an edit (milestone 3 plan HE-25) removes criteria, so
  # the rows as they are later are not the ones an earlier event saw.
  #
  # The rules it keeps:
  #
  # - One step is open from the task's creation until task.done or
  #   task.cancelled, which close it and open none (L275, L276, EN-30).
  # - A hold interrupts the work step; the waiting step follows the oldest
  #   open hold; when the last hold lifts, the step the task's state calls
  #   for opens (L277, L173). That state is the log folded with no holds.
  # - Within one command a task's open step changes at most once (steps.json,
  #   derived rule): a step opened earlier in the same command is changed in
  #   place, so a failed review at the round limit closes review and opens
  #   wait_owner, with no wait_builder row between them. A command's events
  #   share their at and effective_at; a timer's do too.
  # - The criterion back-fill (rule 5, L279): when a criterion passes, an
  #   open build step with no criterion, of the same seat and round, is
  #   given it.
  # - During rework, criterion.started and criterion.passed open no step
  #   (EN-10); the reviewer's acknowledgement opens none (EN-27).
  # - criterion.started opens a new build row (SM-25), also for the
  #   criterion the open row already names: a run that continues work after
  #   a handoff announces its criterion again (milestone 3 plan HD-9,
  #   traces 13 and 14). In one command it changes the row in place.
  # - The seat responsible (L278, rule 4): the builder's working steps,
  #   review, and the two waits that are the holder's (wait_seat, wait_limit)
  #   name a seat; the other waiting steps name none.
  # - wait_ready's cause is fixed when it opens (rule 8): from the
  #   wait_cause of the event that opens it, which is hold.closed when the
  #   task left its seat under a seat-bound hold (milestone 3 plan HE-35).
  #
  # Milestone 4 (its plan, WP5; steps.json; SM-24, RD-11, RC-16):
  #
  # - check opens at the first check.queued of a pending transition (a
  #   blocking model check; a warn check opens no step), with the
  #   transition as its subject, and stays open until the transition
  #   ends: its completion (task.ready, task.claimed, task.submitted,
  #   review.passed, review.failed), a failed check, a withdrawn one when
  #   none of the transition's checks is left running, an errored one at
  #   task.before_claim (the provisional claim lapses, L392), or the
  #   task leaving its seat. A check that ends in error elsewhere keeps it
  #   pending under check_error, whose hold names the step.
  # - Where a transition ends with no completion, the step goes back to
  #   the one the hook leaves: wait_contract (task.before_ready),
  #   wait_ready (task.before_claim, with the check.finished's
  #   wait_cause), finish for the builder (task.before_submit, steps.json)
  #   and review for the reviewer (task.before_done, until the row's own
  #   event moves it).
  # - The check step closes at the last event of the command its
  #   closed_by names: a check.finished written first and the event that
  #   ends the transition after it (a release, the lease's end, a cancel,
  #   a hold, a failed review, a completion) are one change, and the step
  #   closes and the next opens at the latter (traces 16 and 18).
  # - draft opens at job.claimed of a contract draft's job, for the
  #   planner, and job.timed_out or job.withdrawn of that job reopens
  #   wait_contract (SM-24). A contract_incomplete hold opens a new
  #   wait_contract row (SM-24).
  # - wait_review names the provider rule (cause_kind rule, cause_rule_id)
  #   from the check.finished of an applied row at review.assign with
  #   effect refused, once per wait (RD-11).
  #
  # In Finishing, blocking checks name the first action still waiting in
  # contract order. Once approvals settle, wait_builder names the first
  # approved action until the builder acknowledges and opens finish.
  # A hold interrupts either step as usual.
  module Steps
    # A contract event added without step-tracker behavior.
    class Unsupported < StandardError; end

    # What the task's open step is, or would be with no hold open.
    Work = Data.define(:kind, :subject_kind, :subject_id, :seat_id, :round, :cause_kind, :cause_rule_id)

    # The task is done or cancelled: no step is open and none opens.
    ENDED = :ended

    TERMINAL = %w[task.done task.cancelled].freeze
    HOLD_EVENTS = %w[hold.opened hold.closed].freeze
    CRITERIA_EVENTS = %w[task.contract_changed criterion.passed criterion.reopened].freeze

    # The events the fold uses to derive work steps.
    HANDLED = %w[
      task.created task.promoted task.returned task.ready task.claimed task.briefing_acknowledged criterion.started
      criterion.passed task.submitted review.started review.released review.lease_expired review.failed review.passed
      task.released task.lease_expired task.done task.cancelled hold.opened hold.closed task.reassigned
      task.returned_for_rework action.approved action.stopped action.waived action.marked_done action.reported_done
      action.lease_granted check.queued check.finished job.claimed job.timed_out job.withdrawn
    ].freeze

    # Which seat a working step names (L278): the builder's steps name the
    # builder, review the reviewer, draft the planner; waiting steps name
    # none but these.
    BUILDER_STEPS = %w[briefing build finish rework wait_builder].freeze
    SEAT_STEPS = (BUILDER_STEPS + %w[review draft]).freeze
    # The waiting steps of a hold bound to the seat that holds the task:
    # they name that seat (traces 11, 14 and 15).
    HOLDER_WAITS = %w[wait_seat wait_limit].freeze

    # The step that late-binds its close (see the module's comment).
    CHECK = "check".freeze
    PENDING_SUBJECT = "pending_transition".freeze
    DRAFT_JOB = "contract_draft".freeze
    # Check events whose latest one says a check is still to be settled:
    # queued (running), or ended in error (pending under check_error).
    CHECK_EVENTS = %w[check.queued check.finished check.overridden].freeze

    ACTION_STATES = {
      "action.requested" => "requested", "action.approved" => "approved", "action.started" => "started",
      "action.stopped" => "stopped", "action.waived" => "waived", "action.reported_done" => "done",
      "action.marked_done" => "done", "action.withdrawn" => "contracted", "action.revoked" => "revoked"
    }.freeze

    module_function

    # Called by EventLog.append for every event it inserts.
    #
    # _ctx  - the command's Transitions::Context, unused: the tracker reads
    #         the log, so a replay can call it with any context.
    # event - the Event just inserted.
    def on_event(_ctx, event)
      return unless event.task_id && (HANDLED.include?(event.type) || named_events.include?(event.type))
      raise Unsupported, "no step handling for #{event.type}" unless HANDLED.include?(event.type)

      open = TaskStep.find_by(workspace_id: event.workspace_id, task_id: event.task_id, closed_at: nil)
      before, after = open_holds_around(event)
      criteria = Criteria.new(event)
      if before.empty?
        backfill(open, event)
        work = work_of(open, event)
      else
        work = fold(event, criteria)
        criteria.observe(event)
      end
      wanted = desired(advance(work, event, criteria), after, event, open)
      move(open, wanted, event, again: announced_again?(open, wanted, event) || incomplete_contract?(event, wanted))
    end

    # The step the task would have after event with no hold.
    #
    # work     - the Work before the event, nil before task.created, or
    #            ENDED.
    # criteria - answers all_build_passed? as of the event, the event
    #            included.
    def advance(work, event, criteria)
      return ENDED if work == ENDED
      return ENDED if TERMINAL.include?(event.type)
      return created(event) if event.type == "task.created"
      return work if work.nil?

      round = [ work.round, event.round ].max
      payload = event.payload || {}
      case event.type
      when "task.promoted", "task.returned"
        step("wait_contract", round: round)
      when "task.ready", "task.reassigned"
        step("wait_ready", round: round, cause_kind: wait_cause(payload))
      when "task.released", "task.lease_expired"
        work.subject_kind == "action" ? work : step("wait_ready", round: round, cause_kind: wait_cause(payload))
      when "task.claimed"
        step("briefing", seat_id: payload["seat_id"] || event.actor_id, round: round)
      when "task.briefing_acknowledged"
        acknowledged(work, event, criteria, round)
      when "criterion.started"
        started(work, event, round)
      when "criterion.passed"
        passed(work, criteria, round)
      when "task.submitted", "review.released", "review.lease_expired"
        step("wait_review", subject: [ event.subject_kind, event.subject_id ], round: round)
      when "review.started"
        step("review", subject: [ "criterion", review_criterion_id(event) ], seat_id: event.actor_id, round: round)
      when "review.failed"
        failed(event, payload, [ round, event.round + 1 ].max)
      when "task.returned_for_rework"
        owner_rework(event, payload, [ round, event.round + 1 ].max)
      when "action.approved", "action.waived", "action.marked_done", "action.reported_done"
        next_action_step(work, event, round)
      when "hold.closed", "action.lease_granted"
        action_lease(work, payload, round)
      when "check.queued"
        queued(work, event, payload, round)
      when "check.finished"
        finished(work, event, payload, round)
      when "job.claimed"
        draft_job?(event.subject_id) ? step("draft", subject: [ "job", event.subject_id ], seat_id: event.actor_id, round: round) : work
      when "job.timed_out", "job.withdrawn"
        work.kind == "draft" && work.subject_id == event.subject_id ? step("wait_contract", round: round) : work
      else
        # review.passed, action.stopped and hold.opened leave work to the events that follow.
        work
      end
    end

    # The task's events before this one, folded with no hold: the step the
    # task's state calls for while a hold is open. criteria is told each
    # event first, so it answers as of that event.
    def fold(event, criteria)
      events = Event.where(workspace_id: event.workspace_id, task_id: event.task_id).where("seq < ?", event.seq)
        .where(type: (HANDLED + CRITERIA_EVENTS).uniq).order(:seq)
      events.reduce(nil) do |work, earlier|
        criteria.observe(earlier)
        HANDLED.include?(earlier.type) ? advance(work, earlier, criteria) : work
      end
    end

    # --- what each event does -------------------------------------------

    def created(event)
      kind = event.payload&.fetch("state", nil) == "imaginarium" ? "idea" : "wait_contract"
      step(kind, round: event.round || 0)
    end

    def acknowledged(work, event, criteria, round)
      return work if event.subject_kind == "review" # the reviewer's (EN-27)

      seat = work.seat_id || event.actor_id
      case work.kind
      when "wait_builder"
        step(work.subject_kind == "review" ? "rework" : "finish", subject: [ work.subject_kind, work.subject_id ],
          seat_id: seat, round: round)
      when "briefing"
        step(criteria.all_build_passed? ? "finish" : "build", seat_id: seat, round: round)
      else
        work
      end
    end

    def started(work, event, round)
      return work unless work.kind == "build" && work.subject_id != event.subject_id

      step("build", subject: [ "criterion", event.subject_id ], seat_id: work.seat_id, round: round)
    end

    def passed(work, criteria, round)
      return work unless work.kind == "build" && criteria.all_build_passed?

      step("finish", seat_id: work.seat_id, round: round)
    end

    # The first check.queued of a pending transition opens check; a warn
    # check's has none and opens no step (RC-16).
    def queued(work, event, payload, round)
      return work unless payload["blocking"]
      return next_action_step(work, event, round) if payload["action_id"]

      pending = payload["pending_transition_id"]
      return work unless pending
      return work if work.kind == CHECK && work.subject_id == pending

      step(CHECK, subject: [ PENDING_SUBJECT, pending ], round: round)
    end

    # A check of the open check step's transition that ends it goes back to
    # the step its hook leaves; the provider rule refusing a reviewer names
    # the wait (RD-11).
    def finished(work, event, payload, round)
      return refused_reviewer(work, payload) if payload["hook"] == "review.assign"
      return work unless work.kind == CHECK && ends_pending?(work.subject_id, event, payload)

      case payload["hook"]
      when "task.before_ready" then step("wait_contract", round: round)
      when "task.before_claim" then step("wait_ready", round: round, cause_kind: wait_cause(payload))
      when "task.before_submit" then step("finish", seat_id: prior(work.subject_id, event)&.seat_id, round: round)
      when "task.before_done"
        before = prior(work.subject_id, event)
        before ? before.with(round: [ before.round, round ].max) : work
      else work
      end
    end

    # Whether this check.finished ends the pending transition: a failed
    # check refuses it (rule 7); an errored one lapses a provisional claim
    # (L392) and elsewhere leaves it pending; a withdrawn one ends it once
    # none of its checks is still running or errored. A check of another
    # transition, or a passed one, ends nothing (the completion does).
    def ends_pending?(pending, event, payload)
      return false unless queued_for(event)&.payload&.fetch("pending_transition_id", nil) == pending

      case payload["result"]
      when "failed" then true
      when "error" then payload["hook"] == "task.before_claim"
      when "withdrawn" then unsettled_checks(pending, event).empty?
      else false
      end
    end

    def refused_reviewer(work, payload)
      return work unless work.kind == "wait_review" && work.cause_kind.nil?
      return work unless payload["result"] == "applied" && payload["effect"] == "refused"

      work.with(cause_kind: "rule", cause_rule_id: payload["rule_id"])
    end

    def failed(event, payload, round)
      if payload["lease_seat_id"]
        step("wait_builder", subject: [ event.subject_kind, event.subject_id ], seat_id: payload["lease_seat_id"],
          round: round)
      else
        step("wait_ready", round: round, cause_kind: wait_cause(payload))
      end
    end

    def owner_rework(event, payload, round)
      seat = payload["lease_seat_id"]
      return step("wait_ready", round: round, cause_kind: wait_cause(payload)) unless seat

      review_id = task_events(event).where(type: "review.passed").order(seq: :desc).pick(:subject_id)
      step("wait_builder", subject: [ "review", review_id ], seat_id: seat, round: round)
    end

    # Use the event sequence rather than the current action rows. Requests
    # arrive in contract order. A request can have several consecutive
    # checks, and stays on the same step between those checks.
    def next_action_step(work, event, round)
      states = {}
      queued = Set.new
      task_events(event).where(type: ACTION_STATES.keys + [ "check.queued" ]).order(:seq)
        .pluck(:type, :subject_id, :payload).each do |type, id, payload|
          if type == "check.queued"
            queued.add(payload["action_id"]) if payload["blocking"] && payload["action_id"]
          else
            if type == "action.requested"
              states.delete(id)
              queued.delete(id)
            end
            states[id] = ACTION_STATES.fetch(type)
          end
        end

      waiting = states.find { |id, state| state == "requested" && queued.include?(id) }
      return step(CHECK, subject: [ "action", waiting.first ], round: round) if waiting
      return work if states.value?("requested") || states.value?("stopped")

      approved = states.find { |_id, state| %w[approved started].include?(state) }
      return work unless approved

      lease_seat = event.payload["lease_seat_id"]
      seat = lease_seat || (work.seat_id if work.subject_kind == "action") || last_builder(event)
      kind = work.kind == "finish" && lease_seat.nil? ? "finish" : "wait_builder"
      step(kind, subject: [ "action", approved.first ], seat_id: seat, round: round)
    end

    def action_lease(work, payload, round)
      seat = payload["lease_seat_id"]
      return work unless seat && work.subject_kind == "action"

      step("wait_builder", subject: [ "action", work.subject_id ], seat_id: seat, round: round)
    end

    def last_builder(event)
      type, actor, payload = task_events(event).where(type: %w[task.claimed task.returned_for_rework review.failed])
        .order(seq: :desc).pick(:type, :actor_id, :payload)
      return unless payload

      type == "task.claimed" ? payload["seat_id"] || actor : payload["lease_seat_id"]
    end

    def task_events(event)
      Event.where(workspace_id: event.workspace_id, task_id: event.task_id).where("seq <= ?", event.seq)
    end

    # --- writing the rows --------------------------------------------------

    # The step to have open after the event: none once the task has ended,
    # the oldest open hold's while any is open, otherwise the work's.
    #
    # The seat a holder's wait names is the one that holds the task; in the
    # command where it loses the task, between task.released or
    # task.lease_expired and the hold.closed that follows (SM-15), the task
    # has none, and the open step keeps the seat it opened with (rule 8).
    def desired(work, holds, event, open = nil)
      return nil if work == ENDED || work.nil?
      return opened_at_hold_closed(work, event) if holds.empty?

      oldest = holds.first
      kind = hold_step(oldest.fetch(:reason))
      seat_id = work.seat_id || (open.seat_id if open&.kind == kind)
      subject =
        case kind
        when "wait_owner" then [ "hold", oldest.fetch(:id) ]
        when "wait_limit" then [ "credential", oldest.fetch(:credential_id) ]
        when "wait_seat" then [ "seat", seat_id ]
        else [ nil, nil ]
        end
      step(kind, subject: subject, seat_id: seat_id, round: [ work.round, event.round ].max)
    end

    # The last hold lifting opens the step the task's state calls for; a
    # wait_ready that opens there takes the cause hold.closed carries
    # (HE-35), not the one of the event that sent the task to Ready under
    # the hold.
    def opened_at_hold_closed(work, event)
      return work unless event.type == "hold.closed" && work.kind == "wait_ready"

      work.with(cause_kind: wait_cause(event.payload || {}))
    end

    # Whether criterion.started announces, in a later command, the criterion
    # the open build row already names: a new row all the same (SM-25).
    def announced_again?(open, wanted, event)
      event.type == "criterion.started" && open&.kind == "build" && wanted&.kind == "build" &&
        open.subject_id == event.subject_id && wanted.subject_id == event.subject_id
    end

    # The criterion back-fill (rule 5, L279): a criterion passes while the
    # open step is a build step with no criterion, of the same seat and
    # round, and the row is given it, before it closes or stays open.
    def backfill(open, event)
      return unless event.type == "criterion.passed" && open&.kind == "build" && open.subject_id.nil?
      return unless open.seat_id == event.actor_id && open.round == event.round

      open.update!(subject_kind: "criterion", subject_id: event.subject_id)
    end

    def move(open, wanted, event, again: false)
      return if open.nil? && wanted.nil?
      return if late_close(open, wanted, event)
      return if open && wanted && same?(open, wanted) && !(again && !same_command?(open, event))

      if open && wanted && same_command?(open, event)
        open.update!(row(wanted, event).merge(round: [ open.round, wanted.round ].max))
        return
      end

      open&.update!(closed_at: event.effective_at, closing_event_id: event.id)
      TaskStep.create!(row(wanted, event).merge(workspace_id: event.workspace_id, task_id: event.task_id)) if wanted
    end

    # A check step closes at the last event of the command its closed_by
    # names (see the module's comment): when an earlier event of this
    # command closed check and opened the open step, and this event also
    # closes check and opens the step wanted now (or ends the task), the
    # change moves to this event, so the command still changes the step
    # once. Escalation likewise uses task.reassigned for Ready, and a task
    # ending after a hold lifts closes the waiting step at its terminal
    # event. Returns whether it moved the change.
    def late_close(open, wanted, event)
      return false unless open && same_command?(open, event)

      closed = TaskStep.find_by(workspace_id: event.workspace_id, task_id: event.task_id,
        closing_event_id: open.opening_event_id)
      return false unless closed
      return false unless (closed.kind == CHECK && closes?(CHECK, event.type)) ||
        (closed.kind == "wait_owner" && TERMINAL.include?(event.type)) ||
        (event.type == "task.reassigned" && wanted&.kind == "wait_ready")

      if wanted.nil?
        open.destroy!
      elsif opens?(wanted.kind, event.type)
        open.update!(row(wanted, event).merge(round: [ open.round, wanted.round ].max))
      else
        return false
      end
      closed.update!(closed_at: event.effective_at, closing_event_id: event.id)
      true
    end

    # Whether a contract_incomplete hold opens: a new wait_contract row
    # even while one is open (SM-24).
    def incomplete_contract?(event, wanted)
      event.type == "hold.opened" && event.payload&.fetch("reason", nil) == "contract_incomplete" &&
        wanted&.kind == "wait_contract"
    end

    def row(work, event)
      { kind: work.kind, step_class: step_class(work.kind), round: work.round, subject_kind: work.subject_kind,
        subject_id: work.subject_id, seat_id: work.seat_id, cause_kind: work.cause_kind, cause_rule_id: work.cause_rule_id,
        opened_at: event.effective_at, opening_event_id: event.id }
    end

    def same?(open, work)
      [ open.kind, open.subject_kind, open.subject_id, open.seat_id, open.cause_kind, open.cause_rule_id ] ==
        [ work.kind, work.subject_kind, work.subject_id, work.seat_id, work.cause_kind, work.cause_rule_id ]
    end

    # Whether the open step was opened by an earlier event of the same
    # command: same at (the command's clock, read once under the lock) and
    # effective_at. The key is not compared: a pending transition completed
    # inside another command writes under its requester's key (milestone 4
    # plan RE-3), and a timer applied inside a command writes none but has
    # its own effective time.
    def same_command?(open, event)
      return false unless open.opened_at == event.effective_at

      opener = Event.where(id: open.opening_event_id).pick(:at, :effective_at)
      opener == [ event.at, event.effective_at ]
    end

    def work_of(open, event)
      return (event.type == "task.created" ? nil : ENDED) unless open

      Work.new(kind: open.kind, subject_kind: open.subject_kind, subject_id: open.subject_id, seat_id: open.seat_id,
        round: open.round, cause_kind: open.cause_kind, cause_rule_id: open.cause_rule_id)
    end

    # --- small readers -------------------------------------------------

    # A Work for a step kind.
    def step(kind, round:, subject: [ nil, nil ], seat_id: nil, cause_kind: nil, cause_rule_id: nil)
      seat_id = nil unless SEAT_STEPS.include?(kind) || HOLDER_WAITS.include?(kind)
      Work.new(kind: kind, subject_kind: subject.first, subject_id: subject.last, seat_id: seat_id, round: round,
        cause_kind: cause_kind, cause_rule_id: cause_rule_id)
    end

    def wait_cause(payload)
      payload["wait_cause"] == "credential_limit" ? "credential_limit" : nil
    end

    def review_criterion_id(event)
      Criterion.where(workspace_id: event.workspace_id, id: criteria_as_of(event).to_a, kind: "review")
        .order(:position).pick(:id)
    end

    # The ids of the task's criteria as of an event: added by a
    # task.contract_changed up to it and not removed since. A criterion's
    # kind never changes (ContractDiff keeps an id by position and kind).
    def criteria_as_of(event)
      Event.where(workspace_id: event.workspace_id, task_id: event.task_id, type: "task.contract_changed")
        .where("seq <= ?", event.seq).order(:seq).pluck(:payload).each_with_object(Set.new) do |payload, ids|
          ids.merge(Array(payload["added_criterion_ids"]))
          ids.subtract(Array(payload["removed_criterion_ids"]))
        end
    end

    # The task's open holds just before and just after the event, oldest
    # first (log order), each as { id:, reason:, credential_id: }.
    def open_holds_around(event)
      rows = Event.where(workspace_id: event.workspace_id, task_id: event.task_id, type: HOLD_EVENTS)
        .where("seq <= ?", event.seq).order(:seq).pluck(:seq, :type, :subject_id, :payload)
      before = {}
      after = {}
      rows.each do |seq, type, hold_id, payload|
        [ (before unless seq == event.seq), after ].compact.each do |set|
          type == "hold.opened" ? set[hold_id] = hold_entry(hold_id, payload) : set.delete(hold_id)
        end
      end
      [ before.values, after.values ]
    end

    def hold_entry(id, payload)
      { id: id, reason: payload.fetch("reason"), credential_id: payload["credential_id"] }
    end

    def hold_step(reason)
      @hold_steps ||= Contract.registry.fetch("hold_reasons").to_h { |entry| [ entry.fetch("reason"), entry.fetch("step") ] }
      @hold_steps.fetch(reason)
    end

    # --- what a check or a job is ---------------------------------------

    # The check.queued that queued the check a check.finished ends: its
    # latest before the event.
    def queued_for(event)
      Event.where(workspace_id: event.workspace_id, task_id: event.task_id, type: "check.queued",
        subject_id: event.subject_id).where("seq < ?", event.seq).order(seq: :desc).first
    end

    # The checks of a pending transition still to be settled after the
    # event: queued and not finished, or finished in error (still pending
    # under check_error); an overridden check is settled.
    def unsettled_checks(pending, event)
      ids = Event.where(workspace_id: event.workspace_id, task_id: event.task_id, type: "check.queued")
        .where("seq <= ?", event.seq).where("payload->>'pending_transition_id' = ?", pending).distinct.pluck(:subject_id)
      latest = Event.where(workspace_id: event.workspace_id, task_id: event.task_id, type: CHECK_EVENTS, subject_id: ids)
        .where("seq <= ?", event.seq).order(:seq).pluck(:subject_id, :type, :payload)
        .each_with_object({}) { |(id, type, payload), last| last[id] = [ type, payload ] }
      latest.select do |_id, (type, payload)|
        type == "check.queued" || (type == "check.finished" && payload["result"] == "error" &&
          payload["hook"] != "task.before_claim")
      end.keys
    end

    # The step the task was at just before the transition's first
    # check.queued: whom a refused or cancelled submit or pass goes back to.
    def prior(pending, event)
      first = Event.where(workspace_id: event.workspace_id, task_id: event.task_id, type: "check.queued")
        .where("seq < ?", event.seq).where("payload->>'pending_transition_id' = ?", pending).order(:seq).first
      work = first && fold(first, Criteria.new(first))
      work unless work.nil? || work == ENDED
    end

    # Whether a job is a contract draft's: its kind never changes, as a
    # criterion's does not.
    def draft_job?(job_id) = Job.where(id: job_id).pick(:kind) == DRAFT_JOB

    def closes?(kind, type)
      @closes ||= Contract.steps.fetch("steps").to_h do |entry|
        [ entry.fetch("kind"),
          (entry.fetch("closed_by").map { |item| item.fetch("event") } + Contract.steps.fetch("close_without_opening")).to_set ]
      end
      @closes.fetch(kind).include?(type)
    end

    def opens?(kind, type)
      @opens ||= Contract.steps.fetch("steps").to_h do |entry|
        [ entry.fetch("kind"), entry.fetch("opened_by").to_set { |item| item.fetch("event") } ]
      end
      @opens.fetch(kind).include?(type)
    end

    def step_class(kind)
      @step_classes ||= Contract.steps.fetch("steps").to_h { |entry| [ entry.fetch("kind"), entry.fetch("class") ] }
      @step_classes.fetch(kind)
    end

    def named_events
      @named_events ||= Contract.steps.fetch("steps").flat_map do |entry|
        (entry.fetch("opened_by") + entry.fetch("closed_by")).map { |item| item.fetch("event") }
      end.to_set
    end

    # The task's builder criteria and which have passed, as of an event:
    # the kinds from the criteria rows, passed and reopened from the log.
    class Criteria
      def initialize(event)
        @event = event
        @passed = nil
      end

      # Records one event, in log order: a fold reads the log once and
      # tells it each event before asking. Without it, the answer is read
      # from the log up to the event.
      def observe(event)
        @passed ||= Set.new
        apply_to(@passed, event)
      end

      # Whether every builder criterion has passed.
      def all_build_passed?
        passed = @passed || (@from_log ||= from_log)
        build_ids.all? { |id| passed.include?(id) }
      end

      private

      def build_ids
        @build_ids ||= Criterion.where(workspace_id: @event.workspace_id, id: Steps.criteria_as_of(@event).to_a,
          kind: "build").pluck(:id)
      end

      def from_log
        Set.new.tap do |set|
          Event.where(workspace_id: @event.workspace_id, task_id: @event.task_id, type: CRITERIA_EVENTS)
            .where("seq <= ?", @event.seq).order(:seq).each { |event| apply_to(set, event) }
        end
      end

      def apply_to(set, event)
        case event.type
        when "criterion.passed" then set << event.subject_id
        when "criterion.reopened" then set.delete(event.subject_id)
        when "task.contract_changed"
          payload = event.payload || {}
          (Array(payload["reset_criterion_ids"]) + Array(payload["added_criterion_ids"]) +
            Array(payload["removed_criterion_ids"])).each { |id| set.delete(id) }
        end
      end
    end
  end
end
