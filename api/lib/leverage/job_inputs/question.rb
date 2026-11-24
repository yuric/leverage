module Leverage
  module JobInputs
    # Material for the orchestrator's question job (AP-4, AP-5).
    module Question
      module_function

      def call(job, task)
        question = Questions.for_job(job)
        {
          "question_id" => question.id, "task_id" => task.id, "project_id" => task.project_id,
          "material" => {
            "question" => { "text" => question.text.to_s, "assumption" => question.assumption.to_s, "blocking" => question.blocking },
            "contract" => contract(task), "brief" => brief(task), "earlier_answers" => earlier_answers(task, question)
          }
        }
      end

      def contract(task)
        {
          "title" => task.title.to_s, "goal" => task.goal.to_s, "details" => task.details,
          "criteria" => JobInputs.live_criteria(task).map { |criterion| criterion.slice("text", "kind", "state") },
          "actions" => Action.where(workspace_id: task.workspace_id, task_id: task.id).order(:position)
            .map { |action| action.slice("kind", "description") }
        }
      end

      def brief(task)
        return [] unless task.project_id

        BriefEntry.where(workspace_id: task.workspace_id, project_id: task.project_id).order(:position).map do |entry|
          entry.slice("id", "project_id", "kind", "author_kind", "author_id").merge("text" => entry.text.to_s)
        end
      end

      def earlier_answers(task, question)
        ::Question.where(workspace_id: task.workspace_id, task_id: task.id, outcome: "answered").where.not(id: question.id)
          .order(:answered_at, :id).map { |earlier| earlier.slice("text", "answer", "basis") }
      end

      private_class_method :contract, :brief, :earlier_answers
    end
  end
end
