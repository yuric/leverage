module Leverage
  module Reads
    # The outcome of a command the caller sent (milestone 2 plan WP8, IF-4):
    # the commands row of (caller kind, caller id, key) and the Outcome it
    # stored. A key another caller sent, or none, is nil. Selects only; the
    # caller marks the row read (Transitions::MarkRead.command).
    module CommandOutcome
      Found = Data.define(:row, :outcome)

      module_function

      # Found, or nil.
      def call(workspace_id:, caller_kind:, caller_id:, key:)
        ActiveRecord::Base.transaction do
          _workspace, at = WorkspaceLock.take(workspace_id)
          row = Command.find_by(workspace_id: workspace_id, caller_kind: caller_kind, caller_id: caller_id, key: key)
          row && Found.new(row: row, outcome: Idempotency.outcome_of(row, at: at))
        end
      end
    end
  end
end
