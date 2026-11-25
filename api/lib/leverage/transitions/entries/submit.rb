module Leverage
  module Transitions
    module Entries
      # submit (PRD Lifecycle L88, L120, L502; DB-13, DB-20): the builder
      # submits at task.before_submit with a handoff note and the work
      # reference. The task goes In review; the builder lease ends and no
      # seat holds the task; the builder seat is kept; the round's review row
      # is made with the handoff note and no reviewer. task.submitted is
      # about that review and records only whether the reference changed. A
      # work call, blocked by a hold (L174).
      #
      # After an edit from In review (milestone 3 plan HE-25 (ii)) the round
      # and its review row are kept, with no verdict and no reviewer; the
      # next submit in that round takes that row again, with the new note,
      # rather than making a second one for the round.
      #
      # A null work_reference keeps the task's reference: the field is
      # required but may be null, and the server never opens it, so null
      # does not erase it.
      #
      # Refusals add criteria_incomplete: a builder criterion not passed, or
      # passed with no evidence (L458). 422 invalid for a work reference with
      # sign-in details.
      #
      # Params: id (the task), handoff_note, work_reference.
      #
      # Gated at task.before_submit (milestone 4 plan §2.1). A model check
      # makes it wait with its request kept (RE-2); a failed gate refuses
      # it blocked_by_rule and the builder keeps the task.
      class Submit < Entry
        def load(ctx)
          params = ctx.request.params
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          @reference = params["work_reference"].presence
          problem = LinkRules.work_reference_problem(@reference)
          raise Invalid, problem if problem

          @handoff_note = params["handoff_note"]
        end

        def refusals(_ctx)
          codes = Eligibility.task_refusals(@task, @seat)
          codes << "forbidden" unless @seat.may_deliver
          codes << state_refusal(@task.state)
          codes << "on_hold" if Eligibility.on_hold?(@task)
          codes << { missing: "briefing_not_acknowledged", changed: "briefing_changed" }[
            Briefing.acknowledgement(@task, seat: @seat)]
          codes << "criteria_incomplete" unless criteria_complete?
          codes.compact
        end

        def gate_request_fields(_ctx)
          super.merge(task_id: @task.id, project_id: @task.project_id, round: @task.round)
        end

        def perform(ctx)
          changed = !@reference.nil? && @reference != @task.work_reference
          review = Review.find_by(task_id: @task.id, round: @task.round, verdict: nil)
          review&.update!(handoff_note: @handoff_note)
          review ||= Review.create!(workspace_id: @task.workspace_id, task_id: @task.id, round: @task.round,
            handoff_note: @handoff_note)
          Leases.end_lease(ctx, @task)
          @task.update!(state: "in_review", holder_seat_id: nil, resume_pending_since: nil,
            work_reference: changed ? @reference : @task.work_reference)
          ctx.emit("task.submitted", task: @task, subject: review, payload: { work_reference_changed: changed })
          @result = nil
        end

        private

        # Every builder criterion passed, each with evidence.
        def criteria_complete?
          criteria = Criterion.where(task_id: @task.id, kind: "build", removed_at: nil).to_a
          return true if criteria.empty?
          return false unless criteria.all? { |criterion| criterion.state == "passed" }

          Evidence.where(criterion_id: criteria.map(&:id)).distinct.count(:criterion_id) == criteria.size
        end
      end
    end
  end
end
