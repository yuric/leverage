module Leverage
  module Transitions
    module Entries
      # report_job_limit (PRD L872; milestone 4 plan RD-40): the helper
      # reports that a job's run met a limit.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class ReportJobLimit < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
