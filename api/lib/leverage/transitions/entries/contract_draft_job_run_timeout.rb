module Leverage
  module Transitions
    module Entries
      # The contract_draft_job_run_timeout timer (timers.json;
      # state_machine.json; milestone 4 plan WP7, RD-37, DB-31): a draft job
      # claimed by a planner and not finished within the workspace's check
      # run timeout is queued once more; a second miss ends it and the task
      # stays in Backlog. No item opens for a planner (RD-20). How a miss is
      # written is JobTimer's.
      class ContractDraftJobRunTimeout < JobTimer
      end
    end
  end
end
