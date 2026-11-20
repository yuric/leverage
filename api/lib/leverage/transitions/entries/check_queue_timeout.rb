module Leverage
  module Transitions
    module Entries
      # The check_queue_timeout timer (PRD L398, L399; timers.json;
      # state_machine.json; milestone 4 plan WP7, TM-1; trace 07, commands 4
      # and 5): a rule check's attempt not claimed within its queue timeout
      # (the attempt's queued time plus the rule version's own queue
      # timeout, or the workspace's) is queued once more as a new attempt; a
      # second miss gives the result error. How a miss is written is
      # JobTimer's.
      class CheckQueueTimeout < JobTimer
      end
    end
  end
end
