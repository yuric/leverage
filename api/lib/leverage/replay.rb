require "bigdecimal"
require "set"

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
  #   projects      paused and spent, and which one is the Imaginarium project
  #                 (the workspace's imaginarium_project_id, from
  #                 project.created's imaginarium; none reads as false)
  #   task_steps    every row
  #
  # Holder rules (L781, DB-43): set by task.claimed, and by any event whose
  # payload names lease_seat_id (a failed review's fresh lease, Offer task
  # again); cleared by task.submitted, task.released, task.lease_expired,
  # task.returned, task.cancelled and task.done. A provisional claim (RE-5)
  # sets the holder with the check.queued of its task.before_claim
  # blocking check (claimant_seat_id) and clears it when the last of its
  # blocking checks still running has its result and one of them failed or
  # erred, or every one
  # was withdrawn (a rule turned off leaves the claim waiting on its other
  # checks, L379; the engine decides only then), and with a hold.opened on
  # the task, while the task is still Ready. When its last blocking check
  # passes, the claim completes in that same command (task.claimed, at the
  # same at); a command that ends without it refused the claim because the
  # seat may no longer claim (HD-4: paused, removed, or its login limited
  # or signed out while the claim waited; milestone 4 review, finding 7),
  # and the claim lapsed with no event of its own, so the holder is
  # cleared at the next command's first event, or at the end of the log.
  # The builder is set by task.claimed and a fresh lease on owner rework,
  # and cleared when the task returns to Ready or Backlog or is cancelled. The minimum strength rank and the contract version are set
  # by task.contract_changed, which carries both (the rank is null for
  # none); task.reassigned sets the rank on escalation.
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
  # replay column. Rule checks: a hold.opened that names a check makes its
  # row when nothing has (DB-49); a check.queued makes the row, or runs it
  # again (DB-25: the result goes back to none); check.finished sets the
  # result (an app check's row is made by it, as it has no check.queued);
  # check.overridden sets who and when, from its actor and its time (the
  # command's at, which RuleChecks.override stores). Job events change no
  # replay column.
  #
  # Action definitions come from task.created and task.contract_changed.
  # Their states follow the action machine in the contract.
  module Replay
    # An event that changes a replay column and that the replay does not
    # yet project.
    class Unsupported < StandardError; end

    TASK_COLUMNS = %w[state round holder_seat_id builder_seat_id minimum_strength_rank contract_version].freeze
    STEP_COLUMNS = %w[
      task_id round kind step_class subject_kind subject_id seat_id cause_kind cause_rule_id opened_at closed_at
      opening_event_id closing_event_id
    ].freeze
    ACTION_NOTES = %w[action.lease_granted action.overturn_recorded].freeze
    CLAIM_HOOK = "task.before_claim".freeze
    LEASE_FIELD = "lease_seat_id".freeze
    # Projection keys that are not replay columns.
    INTERNAL = %w[provisional provisional_failed claim_settled_at].freeze
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
      settled = {}
      each_event(workspace_id) do |event|
        lapse_unclaimed(projection, settled, event.at)
        apply(projection, event, review_criteria)
        settled[event.task_id] = true if projection[:tasks][event.task_id]&.key?("claim_settled_at")
      end
      lapse_unclaimed(projection, settled, nil)
      projection
    end

    # The provisional claims whose blocking checks all passed in a command
    # (at) that wrote no task.claimed: they lapsed, refused for the seat
    # (HD-4). Asked before each event of a later command, and at the end.
    def lapse_unclaimed(projection, settled, at)
      settled.keys.each do |task_id|
        task = projection[:tasks][task_id]
        settled_at = task&.[]("claim_settled_at")
        next settled.delete(task_id) if settled_at.nil?
        next if at && settled_at == at

        task.delete("claim_settled_at")
        settled.delete(task_id)
        lapse(task)
      end
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
        projects: project_rows(workspace_id, scope.call(Project))
      }
    end

    def project_rows(workspace_id, projects)
      imaginarium_id = Workspace.where(id: workspace_id).pick(:imaginarium_project_id)
      rows(projects, %w[paused spent]).to_h do |id, row|
        [ id, row.merge("spent" => BigDecimal(row.fetch("spent").to_s), "imaginarium" => id == imaginarium_id) ]
      end
    end

    # --- projecting one event ----------------------------------------------

    def apply(projection, event, review_criteria)
      project_actions(projection.fetch(:actions), event)
      payload = event.payload || {}
      task = projection[:tasks][event.task_id]
      case event.type
      when "task.created"
        projection[:tasks][event.task_id] = { "state" => StoredEvents.task_state(payload.fetch("state")), "round" => 0,
          "holder_seat_id" => nil, "builder_seat_id" => nil, "minimum_strength_rank" => nil, "contract_version" => 0 }
        return
      when /\Arule\./ then return rule(projection, event, payload)
      when /\Acheck\./ then return check(projection, event, payload, task)
      when "project.created"
        projection[:projects][event.project_id] = { "paused" => false, "spent" => BigDecimal("0"),
          "imaginarium" => StoredEvents.imaginarium(payload["imaginarium"]) }
      when "project.paused", "project.resumed"
        projection[:projects].fetch(event.project_id)["paused"] = event.type == "project.paused"
      when "cost.reported"
        spend(projection, event, payload)
      when "hold.opened"
        projection[:holds][event.subject_id] = { "reason" => payload.fetch("reason") }
        held_check(projection, payload["rule_check_id"], payload.fetch("reason"))
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

    # Projects one task's action definitions and states. LogAudit also
    # uses this fold to know which actions still exist when a task ends.
    def project_actions(actions, event)
      case event.type
      when "task.created", "task.contract_changed"
        event.payload.fetch("removed_action_ids", []).each { |id| actions.delete(id) }
        event.payload.fetch("added_action_ids", []).each { |id| actions[id] = { "state" => "contracted" } }
      when /\Aaction\./
        return if ACTION_NOTES.include?(event.type)

        state = action_states[event.type]
        raise Unsupported, "the replay does not project #{event.type} (seq #{event.seq})" unless state

        actions[event.subject_id] = { "state" => state }
      end
    end

    def action_states
      @action_states ||= Contract.state_machine.fetch("action_machine").fetch("transitions")
        .to_h { |row| [ row.fetch("event"), row.fetch("to") ] }.freeze
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
      when "action.requested" then task["state"] = "finishing"
      when "task.reassigned" then task["minimum_strength_rank"] = payload.fetch("minimum_strength_rank")
      when "task.done" then task.merge!("state" => "done", "holder_seat_id" => nil)
      when "task.cancelled" then task.merge!("state" => "cancelled", "holder_seat_id" => nil, "builder_seat_id" => nil)
      when "review.failed"
        payload[LEASE_FIELD] ? task.merge!("state" => "working") : back(task, "ready")
        task["round"] += 1
      when "task.returned_for_rework"
        if (seat = payload[LEASE_FIELD])
          task.merge!("state" => "working", "builder_seat_id" => seat)
        else
          back(task, "ready")
        end
        task["round"] += 1
      end
      task["holder_seat_id"] = payload[LEASE_FIELD] if payload[LEASE_FIELD]
      if ENDS_PROVISIONAL.include?(event.type)
        task.delete("provisional")
        task.delete("provisional_failed")
        task.delete("claim_settled_at")
      end
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
        provisional(task, payload, event.subject_id)
      when "check.finished"
        row["result"] = payload.fetch("result")
        settle_claim_check(task, payload, event.subject_id, event.at)
      when "check.overridden" then row.merge!("overridden_by_user_id" => event.actor_id, "overridden_at" => event.at)
      end
    end

    # The check a rule's hold names (DB-49): the row held at the re-run
    # limit has no other event before it is let through or withdrawn
    # (RD-45), so its hold.opened makes it, with no result.
    def held_check(projection, check_id, reason)
      return unless check_id

      row = (projection[:rule_checks][check_id] ||= { "result" => nil, "overridden_by_user_id" => nil, "overridden_at" => nil })
      # A row held at the re-run limit has no result, also when the row was
      # met before and withdrawn (a release ended the command that held it;
      # meeting it again holds it again, milestone 4 review, finding 2).
      row["result"] = nil if reason == "rerun_limit"
    end

    # A provisional claim's claimant holds the Ready task (RE-5, DB-43),
    # while its blocking claim checks run. A warn rule's check never keeps
    # a claim waiting (Rules::Reentry step 3, RC-16), so it is not among
    # them: a claim with no blocking check is claimed in the same command.
    def provisional(task, payload, check_id)
      return unless task && payload["hook"] == CLAIM_HOOK && payload["claimant_seat_id"] && payload["blocking"]

      task["holder_seat_id"] = payload.fetch("claimant_seat_id")
      (task["provisional"] ||= Set.new) << check_id
    end

    # A claim check's result (DB-43). The engine decides a pending claim
    # only once none of its blocking checks is still running
    # (Rules::Reentry, steps 3 and 6), so the claimant holds the Ready task
    # until then: when the last running blocking check of the claim has
    # its result, a failure or an error among them ends the provisional
    # claim, and so does every one of them withdrawn (a rule turned off
    # leaves the claim waiting on the others, L379); otherwise task.claimed
    # follows. A warn rule's check settles nothing.
    def settle_claim_check(task, payload, check_id, at)
      return unless task && payload["hook"] == CLAIM_HOOK && task["provisional"]&.delete?(check_id)

      result = payload.fetch("result")
      task["provisional_failed"] = true if %w[failed error].include?(result)
      return unless task["provisional"].empty?

      if task.delete("provisional_failed") || result == "withdrawn"
        lapse(task)
      else
        task["claim_settled_at"] = at
      end
    end

    # The provisional claim lapses (DB-43): its check failed, erred or was
    # withdrawn, or a hold opened on the task.
    def lapse(task)
      task.delete("provisional_failed") if task
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
