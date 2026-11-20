module Leverage
  module Reads
    # A task's steps in order with their durations (PRD L269 to L306, L898;
    # milestone 4 plan §2.3, RD-28): what the task page's Timing section
    # shows, the open step measured to as_of.
    #
    # First version (milestone 4 plan §4, the hand-over table): an empty
    # list. WP11 writes it.
    module TaskTimeline
      module_function

      # as_of: - the time the open step is measured to; nil is the
      #          database's clock.
      def call(workspace_id, task_id, as_of: nil)
        []
      end
    end
  end
end
