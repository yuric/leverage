module Leverage
  module Reads
    module Question
      Found = Data.define(:row, :body)

      module_function

      def call(_seat, _question_id, task_id: nil) = {}

      # TaskPage refers to Question without its top-level qualifier.
      # Remove this when WP11 qualifies the model in that reader.
      def where(task_id:) = ::Question.where(task_id: task_id)
    end
  end
end
