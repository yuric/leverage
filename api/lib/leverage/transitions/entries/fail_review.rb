module Leverage
  module Transitions
    module Entries
      # fail_review: Review fails (PRD Lifecycle L91, Rework and escalation
      # L127-L131; milestone 2 plan EN-9, EN-12, EN-13, EN-28). At
      # review.failed the review gets its verdict, the criteria it names and
      # its notes, and its lease ends (it keeps its reviewer, DB-20). The
      # named criteria reopen; the review criterion stays open. No rule
      # escalates in this milestone (EN-5), so the row is does_not_escalate,
      # and task.reassigned is never written:
      #
      #   builder_free  the previous builder holds nothing (a lease of its
      #                 past its due time is ended first, by its timer), is
      #                 enabled, not paused and not removed, and, for a seat
      #                 the app runs, one of its candidates is available for
      #                 the task (milestone 3 plan HE-14): Working again,
      #                 held by it under a fresh lease (lease_seat_id), which
      #                 it must acknowledge again (L127). The lease starts on
      #                 the first available candidate (L690, HD-1): when that
      #                 is not the credential last recorded for the task,
      #                 credential.switched follows the row's own events,
      #                 caused by review.failed and written by the app; the
      #                 seat's run is placed on it (SeatRuns.ensure_run_on);
      #   builder_busy  the task is Ready with no holder and no builder, and
      #                 review.failed names the cause of the wait (HE-35).
      #
      # review.failed, criterion.reopened for each named criterion in the
      # contract's order and cost.reported (EN-12) carry the round that
      # failed (EN-28); then the round goes up by one. When it reaches
      # maximum_rounds plus extra_rounds the task is held with
      # rounds_exceeded (EN-13): Holds.open, after the normal move, writes
      # hold.opened (by the app, caused by review.failed) and inbox.opened
      # (Past the round limit, its facts the round reached), and pauses the
      # fresh lease. A work call, blocked by a hold.
      #
      # 422 invalid when no criterion is named, or one that is not a builder
      # criterion of this task.
      #
      # Params: id (the review), verdict "failed", failed_criteria, notes,
      # tokens, spend.
      class FailReview < Entry
        def load(ctx)
          @params = ctx.request.params
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @review = Review.find_by(id: @params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such review")
          @task = Task.find_by!(id: @review.task_id, workspace_id: ctx.workspace.id)
          named = Array(@params["failed_criteria"]).uniq
          @failed = Criterion.where(task_id: @task.id, kind: "build", removed_at: nil, id: named).order(:position).to_a
          raise Invalid, "A failed review names the builder criteria that failed." if named.empty? || @failed.size != named.size

          @builder = @task.builder_seat_id && Seat.find_by(id: @task.builder_seat_id, workspace_id: ctx.workspace.id)
          # A lease of the builder's that is past its due time has ended
          # (EN-14): its timer is written first, so builder_free reads it
          # ended whether or not the sweep has run.
          Timers.apply_held_by(ctx, @builder)
          @free = Eligibility.builder_free?(@builder, @task, at: ctx.at)
        end

        # A pass whose gate failed (empty until WP4's code).
        def load_for_gate(_ctx, review:, seat:, check:); end

        def refusals(_ctx)
          codes = Eligibility.review_refusals(@review, @seat)
          codes << state_refusal(@task.state, [ "does_not_escalate", @free ? "builder_free" : "builder_busy" ])
          codes << "on_hold" if Eligibility.on_hold?(@task)
          codes << { missing: "briefing_not_acknowledged", changed: "briefing_changed" }[
            Briefing.acknowledgement(@task, seat: @seat, review: @review)]
          codes.compact
        end

        def gate_request_fields(_ctx)
          super.merge(task_id: @task.id, project_id: @task.project_id, round: @task.round, subject_kind: "review",
            subject_id: @review.id)
        end

        def perform(ctx)
          Leases.end_lease(ctx, @review)
          @review.update!(verdict: "failed", failed_criteria: @failed.map(&:id), notes: @params["notes"])
          @failed.each { |criterion| criterion.update!(state: "open", passed_at: nil, passed_by_seat_id: nil) }
          spend = BigDecimal(@params.fetch("spend", 0).to_s)
          if @free
            @task.update!(state: "working", holder_seat_id: @builder.id, spent: @task.spent + spend)
            Leases.grant(ctx, @task)
          else
            Leases.end_lease(ctx, @task)
            @task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil, spent: @task.spent + spend)
          end

          failed = ctx.emit("review.failed", task: @task, subject: @review,
            payload: { failed_criterion_ids: @failed.map(&:id), failed_rule_check_id: nil,
                       lease_seat_id: @free ? @builder.id : nil,
                       wait_cause: @free ? nil : Candidates.wait_cause(@task, ctx.at) })
          @failed.each { |criterion| ctx.emit("criterion.reopened", task: @task, subject: criterion, payload: {}) }
          ctx.emit("cost.reported", task: @task, subject: @review,
            payload: { tokens: @params.fetch("tokens", 0), spend: @params.fetch("spend", 0) })
          place_fresh_lease(ctx, failed) if @free

          reached = @task.round + 1
          if reached >= ctx.workspace.maximum_rounds + @task.extra_rounds
            Holds.open(ctx, task: @task, reason: "rounds_exceeded", cause_id: failed.id, facts: { round: reached })
          end
          @task.update!(round: reached)
          @result = nil
        end

        private

        # HD-1, HE-14: the fresh lease is on the builder's first available
        # candidate; a switch when it is not the one last recorded.
        def place_fresh_lease(ctx, failed)
          return unless @builder.credential_id

          to = Candidates.first_available(@builder, @task, ctx.at)
          if to.id == @task.credential_id
            SeatRuns.ensure_run_on(ctx, @builder, to, @task)
          else
            from = @task.credential_id && Credential.find_by(id: @task.credential_id, workspace_id: @task.workspace_id)
            Handoff.switch(ctx, seat: @builder, to: to, from: from, cause: failed, task: @task)
          end
        end
      end
    end
  end
end
