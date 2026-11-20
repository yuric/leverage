module Leverage
  module Transitions
    module Entries
      # report_signed_out (PRD L684; milestone 3 plan §2.1 rules 5 and 6,
      # HE-8, HE-9, HE-11, HE-12): the helper reports that a run found its
      # login signed out.
      #
      # First version (milestone 3 plan §4, the hand-over table): not built yet.
      # WP3 writes it.
      class ReportSignedOut < Entry
        # Empty for WP3's red run: writes nothing.
        def perform(_ctx)
          @result = nil
        end
      end
    end
  end
end
