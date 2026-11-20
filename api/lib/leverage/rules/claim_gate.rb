module Leverage
  module Rules
    # Red stub (WP3): the claim gate's distinct seats.
    module ClaimGate
      SEATS = 0

      module_function

      def failed_seat_ids(_task, _rule_id) = []

      def reached?(_task, _rule_id, _seat_id) = false
    end
  end
end
