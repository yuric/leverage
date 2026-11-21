module Leverage
  module Transitions
    module Entries
      class AnswerQuestion < Entry
        def load(ctx)
          @question = Question.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such question")
          @task = Task.find_by!(id: @question.task_id, workspace_id: ctx.workspace.id)
        end

        def refusals(_ctx)
          answerable = @task.content_deleted_at.nil? && @task.state != "cancelled" &&
            (@question.outcome == "passed_on" || (@question.outcome == "overturned" && @task.state != "done"))
          guard = answerable ? "question_answerable" : "question_not_answerable"
          [ state_refusal(nil, [ guard ]) ].compact
        end

        def perform(ctx)
          Questions.answer(ctx, @question, by: ctx.actor, text: ctx.request.params.fetch("answer"), basis: "owner")
        end
      end
    end
  end
end
