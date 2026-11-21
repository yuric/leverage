module Leverage
  module Transitions
    module Entries
      # The check_run_timeout timer (PRD L399; timers.json;
      # state_machine.json; milestone 4 plan WP7, TM-1; trace 19, commands
      # 17, 19 and 28): a rule check's attempt claimed and not finished
      # within its run timeout (the attempt's start plus the rule version's
      # own run timeout, or the workspace's) is queued once more as a new
      # attempt; a second miss gives the result error. A result that arrives
      # afterwards is refused (submit_job_result, RD-41). How a miss is
      # written is JobTimer's.
      class CheckRunTimeout < JobTimer
      end
    end
  end
end
