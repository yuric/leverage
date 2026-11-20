require "bigdecimal"

module Leverage
  # The replay (PRD "What the replay test rebuilds" and test 1; DB-43,
  # DB-44; milestone 2 plan §2.1): projects a workspace's log into the
  # replay columns and lists where the tables disagree with it.
  #
  # The replay columns, and nothing else:
  #
  #   tasks         state, round, holder, builder, minimum strength rank,
  #                 contract version
  #   criteria      state       reviews  verdict       actions  state
  #   holds         the open set with reasons
  #   rule_checks   result, and override (who and when)
  #   rules         enabled and current version
  #   projects      paused and spent
  #   task_steps    every row
  #
  # Holder rules (L781, DB-43): set by task.claimed, and by any event whose
  # payload names lease_seat_id (a failed review's fresh lease, Offer task
  # again); cleared by task.submitted, task.released, task.lease_expired,
  # task.returned, task.cancelled and task.done. A provisional claim (RE-5)
  # sets the holder with the check.queued of its task.before_claim check
  # (claimant_seat_id) and clears it with that check's failed, errored or
  # withdrawn check.finished and with a hold.opened on the task, while the
  # task is still Ready. The builder is set by
  # task.claimed and cleared when the task returns to Ready or Backlog or is
  # cancelled. The minimum strength rank and the contract version are set
  # by task.contract_changed, which carries both (the rank is null for
  # none); task.reassigned, escalation's, is not written yet (below).
  #
  # task_steps are rebuilt by driving the step tracker (Steps.on_event)
  # over the log in seq order, inside a transaction that is rolled back:
  # the tracker reads only the log, the task's open step and its criteria's
  # kinds, so the rows it gives are the log's. That proves the rows were
  # written from the log and nothing else; that the tracker's rules are the
  # PRD's is proven by the golden traces and the step partition test.
  #
  # The log does not carry everything the PRD's list names. Inputs that
  # are not replay columns are read from the rows, as the tracker reads
  # them: a criterion's kind (which criterion a passed review passes).
  #
  # Rules (milestone 4): rule.created sets enabled and the current version
  # (version 1), rule.changed and rule.reverted the current version,
  # rule.enabled and rule.disabled the switch; rule.removed changes no
  # replay column. Rule checks: a check.queued makes the row, or runs it
  # again (DB-25: the result goes back to none); check.finished sets the
  # result (an app check's row is made by it, as it has no check.queued);
  # check.overridden sets who and when, from its actor and its time (the
  # command's at, which RuleChecks.override stores). Job events change no
  # replay column.
  #
  # Events that change a replay column but that no command of milestones
  # 2 to 4 writes (outward actions, escalation, owner rework) raise
  # Unsupported, as Steps does: the milestone that writes them teaches the
  # replay.
  module Replay
    # An event that changes a replay column and that the replay does not
    # yet project.
    class Unsupported < StandardError; end

    TASK_COLUMNS = %w[state round holder_seat_id builder_seat_id minimum_strength_rank contract_version].freeze
    STEP_COLUMNS = %w[
      task_id round kind step_class subject_kind subject_id seat_id cause_kind cause_rule_id opened_at closed_at
      opening_event_id closing_event_id
    ].freeze
    UNSUPPORTED = /\A(action\.|task\.reassigned\z|task\.returned_for_rework\z)/
    CLAIM_HOOK = "task.before_claim".freeze
    LAPSES = %w[failed error withdrawn].freeze
    LEASE_FIELD = "lease_seat_id".freeze
    # Projection keys that are not replay columns.
    INTERNAL = %w[provisional].freeze
    # A provisional claim becomes the claim, or ends with the holder.
    ENDS_PROVISIONAL = %w[task.claimed task.released task.cancelled].freeze
    BATCH = 1_000

    module_function

    # Every disagreement between the tables and the log of a workspace, as
    # lines ("tasks <id> round: the log says 1, the table says 7"); empty
    # when the log rebuilds every replay column. Runs in one snapshot of
    # the database (repeatable read when no transaction is open) and
    # changes nothing.
    def diff(workspace_id)
      snapshot do
        compare(project(workspace_id), tables(workspace_id)) +
          compare_steps(rebuilt_steps(workspace_id), table_steps(workspace_id))
      end
    end

    # The replay columns as the log gives them, task_steps aside: a Hash of
    # table name (Symbol) to { id => { column => value } }.
    def project(workspace_id)
      projection = { tasks: {}, criteria: {}, reviews: {}, actions: {}, holds: {}, rule_checks: {}, rules: {}, projects: {} }
      review_criteria = Criterion.where(workspace_id: workspace_id, kind: "review", removed_at: nil).pluck(:task_id, :id)
        .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      each_event(workspace_id) { |event| apply(projection, event, review_criteria) }
      projection
    end

    # The same columns, read from the tables.
    def tables(workspace_id)
      scope = ->(model) { model.where(workspace_id: workspace_id) }
      {
        tasks: rows(scope.call(Task), TASK_COLUMNS),
        criteria: rows(scope.call(Criterion), %w[state]),
        reviews: rows(scope.call(Review), %w[verdict]),
        actions: rows(scope.call(Action), %w[state]),
        holds: rows(scope.call(Hold).where(closed_at: nil), %w[reason]),
        rule_checks: rows(scope.call(RuleCheck), %w[result overridden_by_user_id overridden_at]),
        rules: rows(scope.call(Rule), %w[enabled current_version]),
        projects: rows(scope.call(Project), %w[paused spent]).transform_values do |row|
          row.merge("spent" => BigDecimal(row.fetch("spent").to_s))
        end
      }
    end

    # --- projecting one event ----------------------------------------------

    def apply(projection, event, review_criteria)
      raise Unsupported, "the replay does not project #{event.type} yet (seq #{event.seq})" if UNSUPPORTED.match?(event.type)

      payload = event.payload || {}
      task = projection[:tasks][event.task_id]
      case event.type
      when "task.created"
        projection[:tasks][event.task_id] = { "state" => payload.fetch("state"), "round" => 0, "holder_seat_id" => nil,
          "builder_seat_id" => nil, "minimum_strength_rank" => nil, "contract_version" => 0 }
        return
      when /\Arule\./ then return rule(projection, event, payload)
      when /\Acheck\./ then return check(projection, event, payload, task)
      when "project.created"
        projection[:projects][event.project_id] = { "paused" => false, "spent" => BigDecimal("0") }
      when "project.paused", "project.resumed"
        projection[:projects].fetch(event.project_id)["paused"] = event.type == "project.paused"
      when "cost.reported"
        spend(projection, event, payload)
      when "hold.opened"
        projection[:holds][event.subject_id] = { "reason" => payload.fetch("reason") }
        lapse(task)
      when "hold.closed"
        projection[:holds].delete(event.subject_id)
      when "criterion.started", "criterion.passed", "criterion.reopened"
        projection[:criteria][event.subject_id] = { "state" => CRITERION_STATES.fetch(event.type) }
      when "task.contract_changed"
        (payload.fetch("added_criterion_ids") + payload.fetch("reset_criterion_ids")).each do |id|
          projection[:criteria][id] = { "state" => "open" }
        end
      when "task.submitted"
        projection[:reviews][event.subject_id] = { "verdict" => nil }
      when "review.passed"
        projection[:reviews][event.subject_id] = { "verdict" => "passed" }
        review_criteria.fetch(event.task_id, []).each { |id| projection[:criteria][id] = { "state" => "passed" } }
      when "review.failed"
        projection[:reviews][event.subject_id] = { "verdict" => "failed" }
      end
      move(task, event, payload) if task
    end

    CRITERION_STATES = { "criterion.started" => "started", "criterion.passed" => "passed",
                         "criterion.reopened" => "open" }.freeze

    # What an event does to its task's replay columns.
    def move(task, event, payload)
      case event.type
      when "task.contract_changed"
        task.merge!("contract_version" => payload.fetch("contract_version"),
          "minimum_strength_rank" => payload.fetch("minimum_strength_rank"))
      when "task.ready" then task["state"] = "ready"
      when "task.promoted" then task["state"] = "backlog"
      when "task.returned" then back(task, "backlog")
      when "task.claimed"
        task.merge!("state" => "working", "holder_seat_id" => payload.fetch("seat_id"), "builder_seat_id" => payload.fetch("seat_id"))
      when "task.submitted" then task.merge!("state" => "in_review", "holder_seat_id" => nil)
      when "task.released", "task.lease_expired"
        if task["state"] == "working"
          back(task, "ready")
        else
          task["holder_seat_id"] = nil
        end
      when "task.done" then task.merge!("state" => "done", "holder_seat_id" => nil)
      when "task.cancelled" then task.merge!("state" => "cancelled", "holder_seat_id" => nil, "builder_seat_id" => nil)
      when "review.failed"
        payload[LEASE_FIELD] ? task.merge!("state" => "working") : back(task, "ready")
        task["round"] += 1
      end
      task["holder_seat_id"] = payload[LEASE_FIELD] if payload[LEASE_FIELD]
      task.delete("provisional") if ENDS_PROVISIONAL.include?(event.type)
    end

    # --- rules and rule checks -------------------------------------------------

    def rule(projection, event, payload)
      rules = projection[:rules]
      case event.type
      when "rule.created"
        rules[event.subject_id] = { "enabled" => payload.fetch("enabled"), "current_version" => payload.fetch("version") }
      when "rule.changed", "rule.reverted" then rules.fetch(event.subject_id)["current_version"] = payload.fetch("version")
      when "rule.enabled", "rule.disabled" then rules.fetch(event.subject_id)["enabled"] = event.type == "rule.enabled"
      end
    end

    def check(projection, event, payload, task)
      checks = projection[:rule_checks]
      row = (checks[event.subject_id] ||= { "result" => nil, "overridden_by_user_id" => nil, "overridden_at" => nil })
      case event.type
      when "check.queued"
        row["result"] = nil
        provisional(task, payload)
      when "check.finished"
        row["result"] = payload.fetch("result")
        lapse(task) if payload["hook"] == CLAIM_HOOK && LAPSES.include?(payload.fetch("result"))
      when "check.overridden" then row.merge!("overridden_by_user_id" => event.actor_id, "overridden_at" => event.at)
      end
    end

    # A provisional claim's claimant holds the Ready task (RE-5, DB-43).
    def provisional(task, payload)
      return unless task && payload["hook"] == CLAIM_HOOK && payload["claimant_seat_id"]

      task.merge!("holder_seat_id" => payload.fetch("claimant_seat_id"), "provisional" => true)
    end

    # The provisional claim lapses (DB-43): its check failed, erred or was
    # withdrawn, or a hold opened on the task.
    def lapse(task)
      return unless task && task["state"] == "ready" && task.delete("provisional")

      task["holder_seat_id"] = nil
    end

    # The task returns to Ready or Backlog: no holder and no builder.
    def back(task, state)
      task.merge!("state" => state, "holder_seat_id" => nil, "builder_seat_id" => nil)
    end

    def spend(projection, event, payload)
      project = event.project_id && projection[:projects][event.project_id]
      project["spent"] += BigDecimal(payload.fetch("spend").to_s) if project
    end

    # --- task_steps -----------------------------------------------------------

    def table_steps(workspace_id) = step_rows(workspace_id)

    # The step rows the tracker gives when the log is appended again, read
    # inside a savepoint that is rolled back.
    def rebuilt_steps(workspace_id)
      rebuilt = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        TaskStep.where(workspace_id: workspace_id).delete_all
        each_event(workspace_id) { |event| Steps.on_event(nil, event) if event.task_id }
        rebuilt = step_rows(workspace_id)
        raise ActiveRecord::Rollback
      end
      rebuilt
    end

    def step_rows(workspace_id)
      TaskStep.where(workspace_id: workspace_id).pluck(*STEP_COLUMNS)
        .map { |values| STEP_COLUMNS.zip(values).to_h }
        .sort_by { |row| [ row.fetch("task_id"), row.fetch("opened_at"), row.fetch("opening_event_id"), row.fetch("kind") ] }
    end

    # --- comparing ------------------------------------------------------------

    def compare(log, tables)
      log.keys.flat_map do |table|
        ids = (log.fetch(table).keys + tables.fetch(table).keys).uniq.sort_by(&:to_s)
        ids.flat_map { |id| compare_row(table, id, log.fetch(table)[id], tables.fetch(table)[id]) }
      end
    end

    def compare_row(table, id, from_log, from_table)
      return [ "#{table} #{id}: the table has a row the log does not make" ] if from_log.nil?
      return [ "#{table} #{id}: the log makes a row the table does not have" ] if from_table.nil?

      from_log.keys.excluding(*INTERNAL).filter_map do |column|
        next if from_log[column] == from_table[column]

        "#{table} #{id} #{column}: the log says #{from_log[column].inspect}, the table says #{from_table[column].inspect}"
      end
    end

    def compare_steps(rebuilt, table)
      return [] if rebuilt == table

      missing = rebuilt - table
      extra = table - rebuilt
      missing.map { |row| "task_steps: the log makes #{describe(row)}, which the table does not have" } +
        extra.map { |row| "task_steps: the table has #{describe(row)}, which the log does not make" }
    end

    def describe(row)
      "#{row.fetch("kind")} of task #{row.fetch("task_id")} opened by #{row.fetch("opening_event_id")} " \
        "(#{row.except("task_id", "kind", "opening_event_id").compact.map { |key, value| "#{key} #{value}" }.join(", ")})"
    end

    # --- reading ----------------------------------------------------------------

    def rows(scope, columns)
      scope.pluck(:id, *columns).to_h { |id, *values| [ id, columns.zip(values).to_h ] }
    end

    # Yields the workspace's events in seq order, a batch at a time.
    def each_event(workspace_id, &block)
      after = 0
      loop do
        batch = Event.where(workspace_id: workspace_id).where("seq > ?", after).order(:seq).limit(BATCH).to_a
        batch.each(&block)
        break if batch.size < BATCH

        after = batch.last.seq
      end
    end

    # Runs the block in one snapshot and rolls everything back.
    def snapshot
      result = nil
      options = ActiveRecord::Base.lease_connection.transaction_open? ? { requires_new: true } : { isolation: :repeatable_read }
      ActiveRecord::Base.transaction(**options) do
        result = yield
        raise ActiveRecord::Rollback
      end
      result
    end
  end
end
