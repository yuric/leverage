module Leverage
  module Reads
    # Recovery times (PRD L703; milestone 3 plan HE-17, HE-18): the
    # intervals between an interruption and the event that ends it, of one
    # task or of the whole workspace, computed from events only. Each is a
    # RecoveryTime of openapi.json.
    #
    # First version (milestone 3 plan §4, the hand-over table): an empty
    # list. WP9 computes it.
    module RecoveryTimes
      module_function

      # workspace_id - the workspace.
      # task_id:     - one task's intervals, or nil for every task's.
      # now:         - the time an open interval is measured to; nil is
      #                the database's clock.
      #
      # Returns an Array of Hashes.
      def call(workspace_id, task_id: nil, now: nil)
        []
      end
    end
  end
end
