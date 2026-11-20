module Leverage
  module Transitions
    module Entries
      # report_job_signed_out (PRD L872; milestone 4 plan RD-40): the
      # helper reports that a job's run found its account signed out.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class ReportJobSignedOut < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
