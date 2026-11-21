module Leverage
  module JobResults
    # A question job reports its cost, then answers or passes on (RC-8).
    module Question
      RESULT = "#/components/schemas/QuestionJobResult".freeze

      module_function

      def check_shape(_job, answer)
        if Http::RequestSchema.schemer.ref(RESULT).valid?(answer) && coherent?(answer)
          return
        end

        raise Transitions::Invalid, "A question result must answer with a basis or pass the question on."
      end

      def refusals(task)
        task && !%w[done cancelled].include?(task.state) ? [] : [ "invalid_state" ]
      end

      def perform(ctx, job, task, seat:, answer:, tokens:, spend:)
        question = Questions.for_job(job)
        Costs.report(ctx, task: task, subject: job, tokens: tokens, spend: spend)
        if answer.fetch("outcome") == "answered"
          Questions.answer(ctx, question, by: [ "seat", seat.id ], text: answer.fetch("answer"), basis: answer.fetch("basis"))
        else
          Questions.pass_on(ctx, question)
        end
      end

      def coherent?(answer)
        if answer.fetch("outcome") == "answered"
          answer.fetch("answer").present? && answer.fetch("basis").present?
        else
          answer.fetch("answer").nil? && answer.fetch("basis").nil?
        end
      end

      private_class_method :coherent?
    end
  end
end
