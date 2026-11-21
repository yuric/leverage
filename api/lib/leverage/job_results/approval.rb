module Leverage
  module JobResults
    module Approval
      module_function

      def check_shape(_job, _answer)
        raise NotImplementedError, "not built yet"
      end

      def refusals(_task) = []

      def perform(_ctx, _job, _task, seat:, answer:, tokens:, spend:)
        raise NotImplementedError, "not built yet"
      end
    end
  end
end
