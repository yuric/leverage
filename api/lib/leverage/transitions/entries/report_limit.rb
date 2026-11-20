module Leverage
  module Transitions
    module Entries
      # report_limit (PRD L678-L682; milestone 3 plan §2.1 rules 5 and 6,
      # HE-8, HE-9, HE-22, HE-32, HE-33): the helper reports that a run met a
      # provider limit.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP3 writes it.
      class ReportLimit < Entry
        # Empty for WP3's red run: writes nothing.
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
