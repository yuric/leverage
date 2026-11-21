module V1
  module Agent
    class QuestionsController < BaseController
      def create = run("ask_question", "ask_question", ids: [ :id ])

      def show
        view = Leverage::Reads::Question.call(current_seat, uuid_param!(:qid), task_id: uuid_param!(:id))
        raise NotFound, "No such question" unless view
        return render json: view.to_h, status: :conflict if view.is_a?(Leverage::Transitions::Refusal)

        if %w[answered overturned].include?(view.row.outcome)
          Leverage::Transitions::MarkQuestionRead.call(view.row, seat: current_seat)
        end
        render json: view.body
      end
    end
  end
end
