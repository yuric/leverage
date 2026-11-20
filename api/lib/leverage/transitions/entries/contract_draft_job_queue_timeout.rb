module Leverage
  module Transitions
    module Entries
      # The contract_draft_job_queue_timeout timer (timers.json;
      # state_machine.json; milestone 4 plan WP7, RD-37, DB-31): a draft job
      # not claimed within the workspace's check queue timeout is queued
      # once more; a second miss ends it and the task stays in Backlog, its
      # page offering the button again. How a miss is written is JobTimer's.
      class ContractDraftJobQueueTimeout < JobTimer
      end
    end
  end
end
