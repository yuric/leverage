module Leverage
  module Reads
    # One task's page (get_task; milestone 2 plan MA-20, MA-29, IN-35): the
    # contract, the criteria with their evidence, the actions and questions,
    # every hold, the reviews, the open Needs you items, the task's events in
    # seq order for its log, the names that log needs and its recovery times
    # (milestone 3 plan HE-17, which RecoveryTimes computes from the events
    # alone), and the account the task waits for and when it resets, from
    # Board.waiting, the reading its board card uses (HE-15, HE-16). One
    # snapshot, so the page and as_of_seq are one moment of the log.
    #
    # Milestone 4 (its plan §2.3) adds:
    #
    # - steps, lifetime_seconds and as_of: the Timing section (TaskTimeline),
    #   measured to the database's time read inside the snapshot, so no
    #   step it shows can start after it (L322, L898);
    # - rule_checks: the checklist, one line per check row in order of
    #   creation, each with the version it ran, that version's name and the
    #   date it was saved (an earlier check keeps its own after a Save,
    #   L911), its attempts, the queue and run seconds of its last attempt
    #   (RuleTiming's arithmetic; null while not known), and the two buttons
    #   of RD-28: "Let it through once" (can_override) on a blocking gate's
    #   failed or errored row and on the row held at the re-run limit
    #   (RD-45), "Run it again" (can_rerun) on a blocking gate's errored
    #   row; neither once the row is overridden, nor on a done or cancelled
    #   task. A warn rule's failure let its command through (L337), and a
    #   policy's row is no failure, so neither has a button (RD-49);
    # - pending: the task's waiting command (Board.pending_transitions, the
    #   reading the board card's checking uses), since when, and the rules
    #   whose checks it still waits on: those with no result, or errored,
    #   and not overridden;
    # - draft: where a contract draft stands (RD-37), from the task's
    #   latest contract_draft job: queued, writing while a planner holds
    #   it, not_written after the second miss while the task is still in
    #   Backlog, none otherwise.
    module TaskPage
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      module_function

      # The page, or nil when the workspace has no such task. Raises
      # ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id, task_id)
        Snapshot.call(workspace_id) do |as_of_seq|
          task = Task.find_by(workspace_id: workspace_id, id: task_id)
          next nil unless task

          page(workspace_id, task, as_of_seq)
        end
      end

      # The checks a button is offered on (RD-28).
      LET_THROUGH = %w[failed error].freeze
      ENDED = %w[done cancelled].freeze
      ACTION_STARTED = %w[action.started action.reported_done action.marked_done].freeze

      def page(workspace_id, task, as_of_seq)
        criteria = Criterion.where(task_id: task.id, removed_at: nil).order(:position, :id).to_a
        evidence = Evidence.where(criterion_id: criteria.map(&:id)).where.not(value: nil)
          .order(:created_at, :id).group_by(&:criterion_id)
        reviews = Review.where(task_id: task.id).order(:round, :created_at, :id).to_a
        events = Event.where(workspace_id: workspace_id, task_id: task.id).order(:seq).to_a
        items = InboxItem.where(workspace_id: workspace_id, about_kind: "task", about_id: task.id, state: "open")
          .order(:opened_at, :id).to_a
        holds = Hold.where(task_id: task.id).order(:opened_at, :id).to_a
        waiting = Board.waiting(workspace_id, [ task ], { task.id => holds.select { |hold| hold.closed_at.nil? } })
        as_of = TaskTimeline.database_now
        steps = TaskTimeline.call(workspace_id, task.id, as_of: as_of)

        { task: Shapes.task_summary(task),
          criteria: criteria.map { |criterion| Shapes.criterion(criterion, evidence.fetch(criterion.id, [])) },
          actions: actions(task, items, events),
          any_action_started: events.any? { |event| ACTION_STARTED.include?(event.type) },
          questions: ::Question.where(task_id: task.id).order(:asked_at, :id).map { |question| Question.shape(question) },
          holds: holds.map { |hold| Shapes.hold(hold) },
          **waiting.fetch(task.id),
          reviews: reviews.map { |review| Shapes.review(review) },
          inbox_items: Board.inbox_items(workspace_id, items),
          events: events.map { |event| Shapes.event(event) },
          names: names(workspace_id, task, reviews, events),
          recovery_times: RecoveryTimes.call(workspace_id, task_id: task.id),
          reviewer_seat_exists: Board.reviewer_seat?(workspace_id),
          as_of_seq: as_of_seq,
          steps: steps, lifetime_seconds: TaskTimeline.lifetime_seconds(steps), as_of: Shapes.time(as_of),
          rule_checks: rule_checks(task, holds),
          pending: pending(Board.pending_transitions(workspace_id, [ task.id ])[task.id]),
          draft: draft(task) }
      end

      def actions(task, items, events)
        approved = events.select { |event| event.type == "action.approved" }.index_by(&:subject_id)
        stopped = items.select { |item| item.kind == "stopped_action" }.to_h do |item|
          item.facts.values_at("action_id", "rule_check_id")
        end
        Action.where(task_id: task.id).order(:position, :id).map do |action|
          Shapes.action(action).merge(position: action.position,
            approved_at: (Shapes.time(approved[action.id]&.at) if action.approved_by_kind),
            stopped_by_rule_check_id: stopped[action.id])
        end
      end

      # The checklist (RD-28): every rule check of the task.
      def rule_checks(task, holds)
        checks = RuleCheck.where(workspace_id: task.workspace_id, task_id: task.id).order(:created_at, :id).to_a
        versions = RuleVersion.where(id: checks.map(&:rule_version_id).uniq).index_by(&:id)
        rows = RuleCheckAttempt.where(rule_check_id: checks.map(&:id)).order(:attempt_number).group_by(&:rule_check_id)
        timed = RuleTiming.attempts(checks.map(&:id))
        at_limit = holds.select { |hold| hold.closed_at.nil? && hold.reason == "rerun_limit" }.to_set(&:rule_check_id)
        live = !ENDED.include?(task.state)
        checks.map do |check|
          version = versions.fetch(check.rule_version_id)
          checklist_line(check, version, rows.fetch(check.id, []), timed.fetch(check.id, []).last,
            live && blocking?(version) && check.overridden_at.nil?, at_limit.include?(check.id))
        end
      end

      def checklist_line(check, version, attempts, last, actionable, at_limit)
        { id: check.id, rule_id: check.rule_id, rule_name: version.name, rule_version_id: version.id, version: version.version,
          version_saved_at: Shapes.time(version.created_at), hook: check.hook, moment_name: Rules.moment_name(check.hook),
          round: check.round, checker: version.checker, on_fail: version.on_fail, result: check.result,
          effect: check.effect, reason: check.reason,
          attempts: attempts.map do |attempt|
            { attempt_number: attempt.attempt_number, queued_at: Shapes.time(attempt.queued_at),
              started_at: Shapes.time(attempt.started_at), finished_at: Shapes.time(attempt.finished_at) }
          end,
          queue_seconds: RuleTiming.number(last && RuleTiming.queue_seconds(last)),
          run_seconds: RuleTiming.number(last && RuleTiming.run_seconds(last)),
          overridden_at: Shapes.time(check.overridden_at), overridden_by_user_id: check.overridden_by_user_id,
          override_reason: check.override_reason,
          can_override: actionable && (LET_THROUGH.include?(check.result) || (check.result.nil? && at_limit)),
          can_rerun: actionable && check.result == "error" }
      end

      # A gate whose failure stops the command (L337).
      def blocking?(version) = version.kind == "gate" && version.on_fail == "block"

      # PendingCommand, or nil.
      def pending(transition)
        return nil unless transition

        rule_ids = RuleCheck.where(pending_transition_id: transition.id, overridden_at: nil)
          .where("result IS NULL OR result = 'error'").order(:created_at, :id).pluck(:rule_id).uniq
        { command: transition.command, since: Shapes.time(transition.created_at), waiting_on_rule_ids: rule_ids }
      end

      # Where a contract draft stands (RD-37).
      def draft(task)
        job = Job.where(workspace_id: task.workspace_id, task_id: task.id, kind: "contract_draft")
          .order(:queued_at, :attempt_number, :created_at, :id).last
        case job&.state
        when "queued" then "queued"
        when "claimed" then "writing"
        when "timed_out" then job.attempt_number >= 2 && task.state == "backlog" ? "not_written" : "none"
        else "none"
        end
      end

      # The seats and credentials the task's events, the task row and its
      # reviews carry, each with the name its log shows (IN-35). A removed
      # seat keeps its name.
      def names(workspace_id, task, reviews, events)
        seat_ids = [ task.holder_seat_id, task.builder_seat_id, *reviews.map(&:reviewer_seat_id) ]
        credential_ids = [ task.credential_id, *reviews.map(&:credential_id) ]
        events.each do |event|
          seat_ids << event.actor_id if event.actor_kind == "seat"
          seat_ids << event.subject_id if event.subject_kind == "seat"
          credential_ids << event.subject_id if event.subject_kind == "credential"
          collect_ids(event.payload, seat_ids, credential_ids)
        end

        seats = Seat.where(workspace_id: workspace_id, id: valid(seat_ids)).map { |seat| log_name("seat", seat) }
        credentials = Credential.where(workspace_id: workspace_id, id: valid(credential_ids)).map { |row| log_name("credential", row) }
        (seats + credentials).sort_by { |name| [ name.fetch(:kind), name.fetch(:name), name.fetch(:id) ] }
      end

      def log_name(kind, row) = { kind: kind, id: row.id, name: row.name }

      # Walks a payload for the ids it names: a key ending in seat_id is a
      # seat, one ending in credential_id a credential.
      def collect_ids(value, seat_ids, credential_ids)
        case value
        when Hash
          value.each do |key, inner|
            seat_ids << inner if key.to_s.end_with?("seat_id") && inner.is_a?(String)
            credential_ids << inner if key.to_s.end_with?("credential_id") && inner.is_a?(String)
            collect_ids(inner, seat_ids, credential_ids)
          end
        when Array
          value.each { |inner| collect_ids(inner, seat_ids, credential_ids) }
        end
      end

      def valid(ids) = ids.compact.uniq.grep(UUID)
    end
  end
end
