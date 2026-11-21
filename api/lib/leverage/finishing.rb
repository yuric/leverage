module Leverage
  # Gives completed decisions back to the task's previous builder.
  module Finishing
    GRANT_LIMIT = 5

    module_function

    def settle(ctx, task, by:)
      return unless task.state == "finishing" && Actions.approvals_complete?(task)

      unless Actions.first_approved_open(task)
        Leases.end_lease(ctx, task)
        task.update!(state: "done", holder_seat_id: nil, resume_pending_since: nil)
        return ctx.emit("task.done", task: task, payload: {})
      end
      seat = builder(task)
      if by&.type == "hold.closed" && by.payload["lease_seat_id"]
        task.reload
        grant_lease(ctx, task, seat, paused: Holds.pausing?(task))
        return place_lease(ctx, task, seat, cause: by)
      end
      return if task.holder_seat_id

      lose_builder(ctx, task, cause: by) unless seat&.enabled && seat.removed_at.nil?
    end

    def reenter_action(ctx, action, trigger)
      task = builder_task(action)
      return unless task.state == "finishing" && action.state == "requested"
      return if Actions.owner_approval_holds(action).any?

      Transitions::Gate.reenter_action(ctx, action, trigger)
    end

    def after_command(ctx)
      return unless ctx.workspace

      candidates = waiting_tasks(Task.where(workspace_id: ctx.workspace.id))
      grants = 0
      candidates.each do |task|
        next unless builder_free?(task, at: ctx.at)

        entry = Transitions::Entries::GrantActionLease.new
        as_app(ctx, "grant_action_lease", { "id" => task.id }, key: ctx.request.key) do
          entry.load(ctx)
          if entry.refusals(ctx).empty?
            entry.perform(ctx)
            grants += 1
          end
        end
        break if grants == GRANT_LIMIT
      end
    end

    def builder_free?(task, at: Time.current)
      Eligibility.builder_free?(builder(task), task, at: at)
    end

    def builder_holds_task?(task)
      seat = builder(task)
      seat&.enabled && !seat.paused && seat.removed_at.nil? && task.holder_seat_id == seat.id
    end

    def waiting_for(seat)
      waiting_tasks(Task.where(workspace_id: seat.workspace_id, builder_seat_id: seat.id))
    end

    def lose_builder(ctx, task, cause:)
      actions = Actions.for_task(task).where(state: Actions::OPEN).to_a
      first = actions.first
      return if !first || Holds.open_holds(task).any? { |hold| hold.reason == "action_unconfirmed" }

      announced = Event.where(workspace_id: task.workspace_id, task_id: task.id, round: task.round,
        type: "action.started", subject_id: actions.map(&:id)).exists?
      Holds.open(ctx, task: task, reason: "action_unconfirmed", cause_id: cause&.id,
        facts: { action_ids: actions.map(&:id), approved_by_kind: first.approved_by_kind,
                 approved_by_id: first.approved_by_id, builder_announced_start: announced || actions.any? { |action| action.state == "started" } })
    end

    def open_owner_approval(ctx, action, check: nil, cause: nil)
      return if action.state != "requested" || Actions.owner_approval_holds(action).any?

      Holds.open(ctx, task: builder_task(action), reason: "owner_approval", action_id: action.id, rule_id: check&.rule_id,
        rule_check_id: check&.id, cause_id: cause&.id, facts: { action_id: action.id })
    end

    def prepare_lease(ctx, task, except_holds: [])
      return unless task.state == "finishing" && task.holder_seat_id.nil? &&
        Actions.approvals_complete?(task) && Actions.first_approved_open(task)
      return if (Holds.open_holds(task) - except_holds).any?

      seat = builder(task)
      return unless Eligibility.builder_free?(seat, task, at: ctx.at)

      grant_lease(ctx, task, seat, paused: except_holds.any? { |hold| Holds.pauses?(hold.reason) })
      seat
    end

    def grant_lease(ctx, task, seat, paused:)
      task.update!(holder_seat_id: seat.id, resume_pending_since: nil)
      Leases.grant(ctx, task, paused: paused)
    end

    def place_lease(ctx, task, seat, cause:)
      return unless seat&.credential_id

      candidate = Candidates.first_available(seat, task, ctx.at)
      if task.credential_id == candidate.id
        SeatRuns.ensure_run_on(ctx, seat, candidate, task)
      else
        from = Credential.find_by(id: task.credential_id, workspace_id: task.workspace_id)
        Handoff.switch(ctx, seat: seat, to: candidate, from: from, cause: cause, task: task)
      end
    end

    def as_app(ctx, command, params, key: nil)
      request = PendingTransitions::Requested.new(command: command, workspace_id: ctx.workspace.id,
        requester_kind: nil, requester_id: nil, command_key: key, params: params)
      ctx.as_requester(request, cause_id: nil) { yield }
    end

    def waiting_tasks(scope)
      scope.where(state: "finishing", holder_seat_id: nil).filter_map do |task|
        next if Holds.held?(task) || !Actions.approvals_complete?(task) || !Actions.first_approved_open(task)

        approval = Event.where(workspace_id: task.workspace_id, task_id: task.id, round: task.round,
          type: %w[action.approved action.waived]).order(:seq).last
        [ approval&.effective_at || task.updated_at, task.id, task ]
      end.sort_by { |at, id, _task| [ at, id ] }.map(&:last)
    end

    def builder(task)
      Seat.find_by(workspace_id: task.workspace_id, id: task.builder_seat_id, role: "builder") if task.builder_seat_id
    end

    def builder_task(action) = Task.find_by!(id: action.task_id, workspace_id: action.workspace_id)

    private_class_method :builder, :builder_task, :waiting_tasks, :grant_lease
  end
end
