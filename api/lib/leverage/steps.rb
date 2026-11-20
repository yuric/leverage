module Leverage
  # The step tracker (PRD, Steps and timing, L269-L306; steps.json): it opens
  # and closes a task's steps from the events EventLog appends, in the same
  # call, so the steps commit with the events (L271).
  #
  # It reads only the log, the task's open step and the task's criteria
  # (their kinds), never a row an entry changes, so the order in which an
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
  #   share their command_id, at and effective_at; a timer's do too.
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
  module Steps
    # An event that steps.json says opens or closes a step, but that no
    # milestone-2 command writes (jobs, checks, outward actions, escalation,
    # owner rework). Raised rather than guessing a step; the milestone that
    # writes the event teaches the tracker.
    class Unsupported < StandardError; end

    # What the task's open step is, or would be with no hold open.
    Work = Data.define(:kind, :subject_kind, :subject_id, :seat_id, :round, :cause_kind)

    # The task is done or cancelled: no step is open and none opens.
    ENDED = :ended

    TERMINAL = %w[task.done task.cancelled].freeze
    HOLD_EVENTS = %w[hold.opened hold.closed].freeze
    CRITERIA_EVENTS = %w[task.contract_changed criterion.passed criterion.reopened].freeze

    # The events milestone 2 writes that steps.json names, with what each
    # does in advance. Every other event steps.json names is Unsupported.
    HANDLED = %w[
      task.created task.promoted task.returned task.ready task.claimed task.briefing_acknowledged criterion.started
      criterion.passed task.submitted review.started review.released review.lease_expired review.failed review.passed
      task.released task.lease_expired task.done task.cancelled hold.opened hold.closed
    ].freeze

    # Which seat a working step names (L278): the builder's steps name the
    # builder, review the reviewer; waiting steps name none but these.
    BUILDER_STEPS = %w[briefing build finish rework wait_builder].freeze
    # The waiting steps of a hold bound to the seat that holds the task:
    # they name that seat (traces 11, 14 and 15).
    HOLDER_WAITS = %w[wait_seat wait_limit].freeze

    module_function

    # Called by EventLog.append for every event it inserts.
    #
    # _ctx  - the command's Transitions::Context, unused: the tracker reads
    #         the log, so a replay can call it with any context.
    # event - the Event just inserted.
    def on_event(_ctx, event)
      return unless event.task_id && named_events.include?(event.type)
      raise Unsupported, "milestone 2 writes no #{event.type}; the step it opens is not built" unless HANDLED.include?(event.type)

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
      move(open, wanted, event, again: announced_again?(open, wanted, event))
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
      when "task.ready", "task.released", "task.lease_expired"
        step("wait_ready", round: round, cause_kind: wait_cause(payload))
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
      else
        work # review.passed (task.done follows in milestone 2), hold.opened, hold.closed
      end
    end

    # The task's events before this one, folded with no hold: the step the
    # task's state calls for while a hold is open. criteria is told each
    # event first, so it answers as of that event.
    def fold(event, criteria)
      events = Event.where(workspace_id: event.workspace_id, task_id: event.task_id).where("seq < ?", event.seq)
        .where(type: (named_events.to_a + CRITERIA_EVENTS).uniq).order(:seq)
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

    def failed(event, payload, round)
      if payload["lease_seat_id"]
        step("wait_builder", subject: [ event.subject_kind, event.subject_id ], seat_id: payload["lease_seat_id"],
          round: round)
      else
        step("wait_ready", round: round, cause_kind: wait_cause(payload))
      end
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
      return if open && wanted && same?(open, wanted) && !(again && !same_command?(open, event))

      if open && wanted && same_command?(open, event)
        open.update!(row(wanted, event).merge(round: [ open.round, wanted.round ].max))
        return
      end

      open&.update!(closed_at: event.effective_at, closing_event_id: event.id)
      TaskStep.create!(row(wanted, event).merge(workspace_id: event.workspace_id, task_id: event.task_id)) if wanted
    end

    def row(work, event)
      { kind: work.kind, step_class: step_class(work.kind), round: work.round, subject_kind: work.subject_kind,
        subject_id: work.subject_id, seat_id: work.seat_id, cause_kind: work.cause_kind, cause_rule_id: nil,
        opened_at: event.effective_at, opening_event_id: event.id }
    end

    def same?(open, work)
      [ open.kind, open.subject_kind, open.subject_id, open.seat_id, open.cause_kind ] ==
        [ work.kind, work.subject_kind, work.subject_id, work.seat_id, work.cause_kind ]
    end

    # Whether the open step was opened by an earlier event of the same
    # command: same command_id, at and effective_at.
    def same_command?(open, event)
      return false unless open.opened_at == event.effective_at

      opener = Event.where(id: open.opening_event_id).pick(:command_id, :at, :effective_at)
      opener == [ event.command_id, event.at, event.effective_at ]
    end

    def work_of(open, event)
      return (event.type == "task.created" ? nil : ENDED) unless open

      Work.new(kind: open.kind, subject_kind: open.subject_kind, subject_id: open.subject_id, seat_id: open.seat_id,
        round: open.round, cause_kind: open.cause_kind)
    end

    # --- small readers -------------------------------------------------

    # A Work for a step kind.
    def step(kind, round:, subject: [ nil, nil ], seat_id: nil, cause_kind: nil)
      seat_id = nil unless BUILDER_STEPS.include?(kind) || HOLDER_WAITS.include?(kind) || kind == "review"
      Work.new(kind: kind, subject_kind: subject.first, subject_id: subject.last, seat_id: seat_id, round: round,
        cause_kind: cause_kind)
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

    def step_class(kind)
      @step_classes ||= Contract.steps.fetch("steps").to_h { |entry| [ entry.fetch("kind"), entry.fetch("class") ] }
      @step_classes.fetch(kind)
    end

    # Every event steps.json names in an opened_by or closed_by, the two
    # that close without opening, and the hold events.
    def named_events
      @named_events ||= begin
        steps = Contract.steps
        named = steps.fetch("steps").flat_map do |entry|
          (entry.fetch("opened_by") + entry.fetch("closed_by")).map { |item| item.fetch("event") }
        end
        Set.new(named + steps.fetch("close_without_opening") + HOLD_EVENTS)
      end
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
