module Leverage
  # Empty symbols for the red run of WP1 (milestone 3 plan §2.1 rules 1 to 4
  # and 8). The green commit writes them.
  module Candidates
    module_function

    def for(_seat) = []
    def available?(_credential, _at) = false
    def first_available(_seat, _work, _at) = nil
    def next_after(_seat, _work, _stopped, _at) = nil
    def earliest_reset(_seat, _work, _at) = nil
    def due_at(_seat, _work, _at) = nil
    def any_signed_out?(_seat) = false
    def model_for(_seat, _credential) = nil
    def effort_for(_seat, _credential) = nil
    def wait_cause(_task, _at) = nil
  end
end
