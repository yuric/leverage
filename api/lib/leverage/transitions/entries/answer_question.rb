module Leverage
  module Transitions
    module Entries
      class AnswerQuestion < Entry
        def load(ctx)
          @question = Question.find_by(id: ctx.request.params["id"], workspace_id: ctx.workspace.id) ||
            raise(NotFound, "No such question")
        end

        def refusals(_ctx)
          guard = %w[passed_on overturned].include?(@question.outcome) ? "question_answerable" : "question_not_answerable"
          [ state_refusal(nil, [ guard ]) ].compact
        end

        def perform(ctx)
          Questions.answer(ctx, @question, by: ctx.actor, text: ctx.request.params.fetch("answer"), basis: "owner")
        end
      end
    end
  end
end
