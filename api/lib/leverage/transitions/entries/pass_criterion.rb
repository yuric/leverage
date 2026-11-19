module Leverage
  module Transitions
    module Entries
      # pass_criterion (PRD Lifecycle L87, L497, L533): the builder passes a
      # builder criterion with evidence, an https link or a note that locates
      # the proof inside the work reference. The criterion is passed, by the
      # seat, at the command's time; the evidence row records who attached
      # it; criterion.passed and evidence.attached are written. A work call,
      # blocked by a hold (L174). It clears a pending resume.
      #
      # 404 for a criterion of another task; 422 invalid for the review
      # criterion and for evidence that is not an https link or a note, or
      # that carries sign-in details (LinkRules).
      #
      # Params: id (the task), cid (the criterion), evidence {kind, value}.
      class PassCriterion < Entry
        def load(ctx)
          params = ctx.request.params
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
          @criterion = Criterion.find_by(id: params["cid"], task_id: @task.id, removed_at: nil) ||
            raise(NotFound, "No such criterion")
          raise Invalid, "Only a verdict passes the review criterion." unless @criterion.kind == "build"

          @evidence = params["evidence"].is_a?(Hash) ? params["evidence"] : {}
          problem = LinkRules.evidence_problem(@evidence["kind"], @evidence["value"])
          raise Invalid, problem if problem
        end

        def refusals(_ctx)
          codes = Eligibility.task_refusals(@task, @seat)
          codes << state_refusal(@task.state)
          codes << "on_hold" if Eligibility.on_hold?(@task)
          codes << { missing: "briefing_not_acknowledged", changed: "briefing_changed" }[
            Briefing.acknowledgement(@task, seat: @seat)]
          codes.compact
        end

        def perform(ctx)
          @criterion.update!(state: "passed", passed_at: ctx.at, passed_by_seat_id: @seat.id)
          evidence = Evidence.create!(workspace_id: @task.workspace_id, criterion_id: @criterion.id,
            kind: @evidence.fetch("kind"), value: @evidence.fetch("value"), attached_by_seat_id: @seat.id)
          @task.update!(resume_pending_since: nil) if @task.resume_pending_since
          ctx.emit("criterion.passed", task: @task, subject: @criterion, payload: {})
          ctx.emit("evidence.attached", task: @task, subject: evidence,
            payload: { criterion_id: @criterion.id, kind: evidence.kind })
          @result = nil
        end
      end
    end
  end
end
