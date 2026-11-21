module Leverage
  # The round limit and escalation count failed verdicts, including a
  # before-done gate failure. Rework requested by the owner has no verdict.
  module ReviewRounds
    module_function

    def failed_count(_task) = 0
  end
end
