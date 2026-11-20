module Leverage
  module Transitions
    module Entries
      # submit_job_result (PRD L428, L514; milestone 4 plan RE-6, RE-8,
      # RD-37, RD-41): the job's seat sends its verdict or its contract.
      #
      # First version (milestone 4 plan §4, the hand-over table): not built yet.
      # WP6 writes it.
      class SubmitJobResult < Entry
        def perform(_ctx)
          raise NotImplementedError, "#{command} is not built yet"
        end
      end
    end
  end
end
