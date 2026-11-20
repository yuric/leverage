module Leverage
  module Transitions
    module Entries
      # The contract_draft_job_run_timeout timer (timers.json; milestone 4
      # plan RD-37, DB-31): a draft job not finished in time is queued once
      # more; a second miss ends it.
      #
      # First version (milestone 4 plan §4, the hand-over table): does nothing.
      # WP7 writes it.
      class ContractDraftJobRunTimeout < Entry
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
