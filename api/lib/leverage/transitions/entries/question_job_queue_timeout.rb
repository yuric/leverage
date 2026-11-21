module Leverage
  module Transitions
    module Entries
      class QuestionJobQueueTimeout < JobTimer
        private

        def miss(ctx, job) = Questions.miss_job(ctx, job, due_kind)
      end
    end
  end
end
