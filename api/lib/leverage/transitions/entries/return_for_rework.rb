module Leverage
  module Transitions
    module Entries
      # Reopens work before anything has gone out. The rework's events
      # carry the old round, then the task advances one round (DB-15).
      class ReturnForRework < Entry
        ACTION_HOLDS = %w[action_stopped owner_approval action_unconfirmed].freeze

        def load(ctx)
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such task")
          @criteria = criteria_to_reopen(ctx.request.params["criterion_ids"])
          @builder = Seat.find_by(id: @task.builder_seat_id, workspace_id: ctx.workspace.id)
          if @task.state == "finishing" && !Actions.any_started?(@task)
            Timers.apply_held_by(ctx, @builder)
            @task.reload
          end
        end

        def refusals(_ctx)
          guards = if Actions.any_started?(@task)
            [ "action_started" ]
          else
            [ "no_action_started", builder_availability ]
          end
          [ state_refusal(@task.state, guards) ].compact
        end

        def perform(ctx)
          pending = PendingTransitions.of(@task)
          PendingTransitions.cancel(ctx, pending, "invalid_state") if pending
          holds = action_holds
          Leases.end_lease(ctx, @task)
          fresh = @row.fetch("builder_lease") == "fresh"
          releases_builder = !fresh && @task.holder_seat_id.present?
          seat_id = @builder.id if fresh
          @task.update!(state: @row.fetch("to"), holder_seat_id: seat_id, builder_seat_id: seat_id, resume_pending_since: nil)
          Leases.grant(ctx, @task, paused: Holds.pausing?(@task)) if fresh
          wait_cause = Candidates.wait_cause(@task, ctx.at) unless fresh
          returned = ctx.emit("task.returned_for_rework", task: @task,
            payload: { lease_seat_id: seat_id, wait_cause: (wait_cause unless Holds.held?(@task)) })
          reopen_criteria(ctx)
          Actions.withdraw_open(ctx, @task)
          close_action_holds(ctx, holds, wait_cause)
          Holds.close_seat_bound(ctx, @task, cause: returned, wait_cause: wait_cause) if releases_builder
          place_lease(ctx, returned) if fresh
          @task.update!(round: @task.round + 1, resume_pending_since: nil)
          @result = nil
        end

        private

        def criteria_to_reopen(named)
          active = Criterion.where(workspace_id: @task.workspace_id, task_id: @task.id, removed_at: nil)
          unless named.is_a?(Array) && named.all? { |id| id.is_a?(String) } && active.where(id: named).count == named.size
            raise Invalid, "Name criteria from this task's current contract."
          end

          active.where(id: named).or(active.where(kind: "review")).order(:position).to_a
        end

        def builder_availability
          return "builder_holds_task" if @builder && Permissions.builds?(@builder) && Finishing.builder_holds_task?(@task)
          return "builder_free" if Finishing.builder_free?(@task, lease: :task)

          "builder_busy"
        end

        def reopen_criteria(ctx)
          @criteria.each do |criterion|
            criterion.update!(state: "open", passed_at: nil, passed_by_seat_id: nil)
            ctx.emit("criterion.reopened", task: @task, subject: criterion)
          end
        end

        def action_holds
          open = Holds.open_holds(@task)
          check_errors = open.select { |hold| hold.reason == "check_error" }
          action_checks = RuleCheck.where(workspace_id: @task.workspace_id, task_id: @task.id, subject_kind: "action",
            id: check_errors.map(&:rule_check_id)).pluck(:id).to_set
          open.select do |hold|
            ACTION_HOLDS.include?(hold.reason) || (hold.reason == "check_error" && action_checks.include?(hold.rule_check_id))
          end
        end

        def close_action_holds(ctx, holds, wait_cause)
          open = Holds.open_holds(@task)
          answered = (open & holds)
          answered.each do |hold|
            choice = "return_for_rework" if hold.reason == "action_stopped"
            cause = wait_cause if open == answered && hold == answered.last
            Holds.close(ctx, hold: hold, task: @task, choice: choice, wait_cause: cause)
          end
        end

        def place_lease(ctx, returned)
          return unless @builder.credential_id

          candidate = Candidates.first_available(@builder, @task, ctx.at)
          return unless candidate

          if candidate.id == @task.credential_id
            SeatRuns.ensure_run_on(ctx, @builder, candidate, @task)
          else
            from = Credential.find_by(id: @task.credential_id, workspace_id: @task.workspace_id)
            Handoff.switch(ctx, seat: @builder, to: candidate, from: from, cause: returned, task: @task)
          end
        end
      end
    end
  end
end
