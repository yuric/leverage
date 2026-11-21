module Leverage
  module JobResults
    module Question
      module_function

      def check_shape(_job, _answer); end

      def refusals(_task) = []

      def perform(_ctx, _job, _task, seat:, answer:, tokens:, spend:); end
    end
  end
end
