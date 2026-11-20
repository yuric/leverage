module Leverage
  module Rules
    # Red stub (WP3): every re-entry keeps waiting.
    module Reentry
      module_function

      def call(pending_transition_id:, trigger:) = keep

      def action(action_id:, trigger:) = keep

      def keep
        Gating::Decision.new(action: :keep_pending, failures: [], effects: [], holds_to_open: [], holds_to_close: [],
          checks_to_withdraw: [])
      end
    end
  end
end
