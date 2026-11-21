module Leverage
  module Reads
    # A builder can read a question it asked only while it holds the task.
    # The caller marks a successful read through Transitions::MarkQuestionRead.
    module Question
      Found = Data.define(:row, :body)

      module_function

      # nil for a missing question, a refusal if the seat may not read it,
      # or the row and its representation on success.
      def call(seat, question_id, task_id: nil)
        questions = ::Question.where(workspace_id: seat.workspace_id, id: question_id)
        questions = questions.where(task_id: task_id) if task_id
        question = questions.take
        return unless question

        unless question.asking_seat_id == seat.id && NextItem.held_tasks(seat).exists?(id: question.task_id)
          return Transitions::Refusal.new(code: "not_holder")
        end

        Found.new(row: question, body: shape(question))
      end

      def shape(question)
        Shapes.question(question).merge(asked_at: Shapes.time(question.asked_at),
          answered_at: Shapes.time(question.answered_at), overturned: question.outcome == "overturned")
      end
    end
  end
end
