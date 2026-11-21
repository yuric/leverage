module Leverage
  # Contract definitions and the action state machine. Content stays on rows.
  module Actions
    DefinitionChanges = Data.define(:added_ids, :removed_ids)
    OPEN = %w[approved started].freeze
    RESOLVED = %w[done waived].freeze

    module_function

    def create_for(task, inputs)
      previous = for_task(task).index_by(&:position)
      added = []
      removed = []
      inputs.each_with_index do |input, index|
        position = index + 1
        old = previous.delete(position)
        fields = input.to_h.symbolize_keys.slice(:kind, :description)
        next if old && old.kind == fields[:kind] && old.description == fields[:description]

        removed << remove_definition(old) if old
        added << Action.create!(workspace_id: task.workspace_id, task_id: task.id, position: position, **fields).id
      end
      removed.concat(previous.values.map { |action| remove_definition(action) })
      DefinitionChanges.new(added_ids: added, removed_ids: removed)
    end

    def for_task(task)
      Action.where(workspace_id: task.workspace_id, task_id: task.id).order(:position)
    end

    def request_all(ctx, task)
      eligible(for_task(task), "action.requested").map do |action|
        move(ctx, action, "action.requested", task: task)
        action
      end
    end

    def allows?(action, command)
      transitions.any? { |row| row.fetch("from").include?(action.state) && row.fetch("commands").include?(command) }
    end

    def approve(ctx, action, by:, rule_check: nil)
      task = task_of(action)
      command = rule_check ? "override_check" : "approve_action"
      change = transition!(action, "action.approved", command)
      job = approval_job_check(ctx, action) && ctx.request.params["job_id"]
      action.update!(state: change.fetch("to"), approved_by_kind: by.first, approved_by_id: by.last, approval_job_id: job)
      ignored = rule_check ? holds_for(action, "action_stopped") : owner_approval_holds(action)
      lease = Finishing.prepare_lease(ctx, task, except_holds: ignored)
      event = ctx.emit("action.approved", task: task, subject: action, actor_kind: by.first, actor_id: by.last,
        cause_id: (RuleChecks.last_overridden(rule_check)&.id if rule_check), payload: { lease_seat_id: lease&.id })
      Finishing.place_lease(ctx, task, lease, cause: event)
      event
    end

    def stop(ctx, action, by:, rule_check: nil, reason: nil)
      task = task_of(action)
      command = rule_check ? "request_action" : (ctx.request.command == "overturn_approval" ? "overturn_approval" : "stop_action")
      event = move(ctx, action, "action.stopped", command: command, task: task, actor_kind: by.first, actor_id: by.last,
        cause_id: (RuleChecks.last_finished(rule_check)&.id if rule_check))
      # A gate can stop the action while other gates still run. Their
      # results are needed before the owner can override the failed gate.
      withdraw_checks(ctx, action, task) unless rule_check
      holds_for(action, "check_error").each { |hold| Holds.close(ctx, hold: hold, task: task) }
      owner_approval_holds(action).each { |hold| Holds.close(ctx, hold: hold, task: task, choice: "stop") }
      Holds.open(ctx, task: task, reason: "action_stopped", cause_id: event.id, actor_kind: by.first, actor_id: by.last,
        rule_id: rule_check&.rule_id, rule_check_id: rule_check&.id, action_id: action.id,
        facts: { action_id: action.id, rule_check_id: rule_check&.id, any_action_started: any_started?(task) })
      event
    end

    def start(ctx, action) = move(ctx, action, "action.started")
    def report_done(ctx, action) = move(ctx, action, "action.reported_done")
    def mark_done(ctx, action) = move(ctx, action, "action.marked_done")

    def waive(ctx, action)
      task = task_of(action)
      change = transition!(action, "action.waived", "waive_action")
      action.update!(state: change.fetch("to"))
      ignored = holds_for(action, "action_stopped") + owner_approval_holds(action) + unconfirmed_holds(action)
      lease = Finishing.prepare_lease(ctx, task, except_holds: ignored)
      event = ctx.emit("action.waived", task: task, subject: action, payload: { lease_seat_id: lease&.id })
      Finishing.place_lease(ctx, task, lease, cause: event)
      withdraw_checks(ctx, action, task)
      event
    end

    def withdraw_open(ctx, task)
      eligible(for_task(task), "action.withdrawn").each do |action|
        move(ctx, action, "action.withdrawn", task: task,
          fields: { approved_by_kind: nil, approved_by_id: nil, approval_job_id: nil })
        withdraw_checks(ctx, action, task)
      end
    end

    def revoke_open(ctx, task)
      eligible(for_task(task), "action.revoked").each { |action| move(ctx, action, "action.revoked", task: task) }
    end

    def record_overturn(ctx, action)
      raise ArgumentError, "only a completed approval may be recorded" unless action.state == "done"

      ctx.emit("action.overturn_recorded", task: task_of(action), subject: action, payload: {})
    end

    def grant_lease(ctx, action, task)
      seat = Finishing.prepare_lease(ctx, task)
      return unless seat

      event = ctx.emit("action.lease_granted", task: task, subject: action, payload: { lease_seat_id: seat.id },
        actor_kind: "app", actor_id: nil)
      Finishing.place_lease(ctx, task, seat, cause: event)
      event
    end

    def approvals_complete?(task, except: nil)
      !for_task(task).where.not(id: except&.id).where.not(state: OPEN + RESOLVED).exists?
    end

    def last_open?(action)
      !Action.where(workspace_id: action.workspace_id, task_id: action.task_id).where.not(id: action.id)
        .where.not(state: RESOLVED).exists?
    end

    def any_started?(task)
      for_task(task).where(state: %w[started done]).exists? ||
        Event.where(workspace_id: task.workspace_id, task_id: task.id, round: task.round,
          type: %w[action.started action.reported_done action.marked_done]).exists?
    end

    def first_approved_open(task) = for_task(task).where(state: OPEN).first

    def stopped_by_check?(action)
      action.state == "stopped" && holds_for(action, "action_stopped").any? { |hold| hold.rule_check_id.present? }
    end

    def owner_approval_holds(action) = holds_for(action, "owner_approval")

    def holds_for(action, reason)
      holds = Hold.where(workspace_id: action.workspace_id, task_id: action.task_id, reason: reason, closed_at: nil)
      holds.order(:opened_at, :id).select do |hold|
        hold.action_id == action.id || (hold.action_id.nil? &&
          InboxItem.where(hold_id: hold.id, state: "open").any? { |item| item.facts["action_id"] == action.id })
      end
    end

    def unconfirmed_holds(action)
      Hold.where(workspace_id: action.workspace_id, task_id: action.task_id, reason: "action_unconfirmed", closed_at: nil)
        .select do |hold|
          InboxItem.where(hold_id: hold.id, state: "open").any? { |item| Array(item.facts["action_ids"]).include?(action.id) }
        end
    end

    def approval_job_check(ctx, action)
      id = ctx.request.params["job_id"]
      return unless id
      return unless ctx.events.any? do |event|
        event.type == "job.finished" && event.subject_id == id && event.actor_id == ctx.request.caller_id &&
          event.command_id == ctx.request.key
      end

      job = Job.find_by(id: id, workspace_id: action.workspace_id, task_id: action.task_id, kind: "approval",
        state: "finished", claimed_by_seat_id: ctx.request.caller_id)
      return unless job

      check = action_checks(action).find_by(id: job.target_id, result: "applied")
      check if check && RuleCheckAttempt.exists?(rule_check_id: check.id, job_id: job.id)
    end

    def withdraw_checks(ctx, action, task)
      checks = action_checks(action).where(round: task.round, overridden_at: nil)
      # An errored approval has already passed the decision to the owner.
      errored_gates = checks.where(result: "error", rule_version_id: RuleVersion.where(kind: "gate").select(:id))
      checks.where(result: nil).or(errored_gates).order(:created_at, :id).each do |check|
        job = RuleChecks.open_job(check)
        Jobs.withdraw(ctx, job) if job
        RuleChecks.withdraw(ctx, check)
      end
    end

    def action_checks(action)
      RuleCheck.where(workspace_id: action.workspace_id, task_id: action.task_id, subject_kind: "action", subject_id: action.id)
    end

    def task_of(action) = Task.find_by!(workspace_id: action.workspace_id, id: action.task_id)

    def transitions = Contract.state_machine.fetch("action_machine").fetch("transitions")

    def eligible(scope, event)
      scope.where(state: transitions.select { |row| row.fetch("event") == event }.flat_map { |row| row.fetch("from") })
    end

    def transition!(action, event, command)
      transitions.find do |row|
        row.fetch("event") == event && row.fetch("from").include?(action.state) &&
          (!command || row.fetch("commands").include?(command))
      end || raise(ArgumentError, "action cannot move from #{action.state} by #{event}")
    end

    def move(ctx, action, event, command: nil, task: task_of(action), fields: {}, **as)
      row = transition!(action, event, command)
      action.update!(state: row.fetch("to"), **fields)
      ctx.emit(event, task: task, subject: action, payload: {}, **as)
    end

    def remove_definition(action)
      Hold.where(action_id: action.id).where.not(closed_at: nil).update_all(action_id: nil)
      action.destroy!.id
    end

    private_class_method :transitions, :eligible, :transition!, :move, :remove_definition, :task_of, :unconfirmed_holds
  end
end
