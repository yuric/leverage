module Leverage
  module Rules
    # Red stub (WP3): the re-run limit.
    module RerunLimit
      module_function

      def runs(task:, rule_id:, hook:, round:, subject_kind:, subject_id:, owner_request: false) = []

      def reached?(task:, rule_id:, hook:, round:, subject_kind:, subject_id:, input_hash:, owner_request: false) = false
    end
  end
end
