module Leverage
  module Transitions
    module Entries
      class AskQuestion < Entry
        def load(ctx)
          @seat = Seat.find_by(id: ctx.request.caller_id, workspace_id: ctx.workspace.id) || raise(NotFound, "No such seat")
          @task = Task.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) || raise(NotFound, "No such task")
        end

        def refusals(_ctx)
          return [ "forbidden" ] unless @seat.role == "builder"

          codes = Eligibility.task_refusals(@task, @seat)
          codes << state_refusal(@task.state)
          codes << { missing: "briefing_not_acknowledged", changed: "briefing_changed" }[Briefing.acknowledgement(@task, seat: @seat)]
          codes.compact
        end

        # The policy's subject is the question that was just asked (RC-8).
        def before_gate(ctx)
          params = ctx.request.params
          @question = Questions.ask(ctx, @task, text: params.fetch("text"),
            assumption: params.fetch("assumption"), blocking: params.fetch("blocking"))
        end

        def gate_request_fields(_ctx)
          super.merge(task_id: @task.id, project_id: @task.project_id, round: @task.round,
            subject_kind: "question", subject_id: @question&.id)
        end

        def perform(ctx)
          @task.update!(resume_pending_since: nil) if @task.resume_pending_since
          check = ctx.events.reverse.find do |event|
            event.type == "check.finished" && event.payload["hook"] == hook &&
              event.payload["subject_id"] == @question.id && event.payload["result"] == "applied"
          end
          Questions.route(ctx, @question, check&.payload&.fetch("effect"))
          @result = { "question_id" => @question.id }
        end
      end
    end
  end
end
