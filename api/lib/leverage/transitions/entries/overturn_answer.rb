module Leverage
  module Transitions
    module Entries
      class OverturnAnswer < Entry
        def load(ctx)
          @question = Question.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such question")
          @task = Task.find_by!(id: @question.task_id, workspace_id: ctx.workspace.id)
        end

        def refusals(_ctx)
          guard = if !%w[done cancelled].include?(@task.state) &&
              @question.outcome == "answered" && @question.answered_by_kind == "seat"
            "orchestrator_answer_not_overturned"
          else
            "no_orchestrator_answer_to_overturn"
          end
          [ state_refusal(nil, [ guard ]) ].compact
        end

        def perform(ctx)
          Questions.overturn(ctx, @question)
        end
      end
    end
  end
end
