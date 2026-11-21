require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::ClaimGate (PRD L393, L166; SM-19): a task that fails a
    # task.before_claim gate for 3 different seats is held with
    # claim_gate_failed. The seats counted have a failed, not overridden
    # check of one rule, contract version and round; an error does not
    # count.
    class ClaimGateTest < ActiveSupport::TestCase
      include TestSupport

      setup do
        @rule = model_gate("task.before_claim")
        @task = scenario.task(state: "ready")
      end

      def failed_for(seat, result: "failed", contract_version: @task.contract_version, round: @task.round, rule: @rule)
        hash = Leverage::Gating.input_hash(hook: "task.before_claim",
          inputs: { "contract_version" => contract_version, "seat_id" => seat.id })
        scenario.rule_check(@task, rule: rule, result: result, subject: seat, input_hash: hash, round: round)
      end

      test "the third distinct seat reaches it" do
        first, second, third = Array.new(3) { scenario.seat }
        failed_for(first)
        failed_for(second)

        assert_equal [ first.id, second.id ].sort, ClaimGate.failed_seat_ids(@task, @rule.id).sort
        assert ClaimGate.reached?(@task, @rule.id, third.id)
        refute ClaimGate.reached?(@task, @rule.id, second.id), "a seat counts once"
      end

      test "an errored, an overridden, another round's, another contract version's or another rule's check does not count" do
        seats = Array.new(6) { scenario.seat }
        failed_for(seats[0], result: "error")
        override(failed_for(seats[1]))
        failed_for(seats[2], round: 1)
        failed_for(seats[3], contract_version: @task.contract_version + 1)
        failed_for(seats[4], rule: model_gate("task.before_claim"))

        assert_empty ClaimGate.failed_seat_ids(@task, @rule.id)
        refute ClaimGate.reached?(@task, @rule.id, seats[5].id)
      end

      test "a task already held with claim_gate_failed for the rule is not held again" do
        first, second, third = Array.new(3) { scenario.seat }
        failed_for(first)
        failed_for(second)
        open_hold(@task, "claim_gate_failed", rule: @rule)

        refute ClaimGate.reached?(@task, @rule.id, third.id)
      end

      test "the number of seats is 3, a constant of the PRD" do
        assert_equal 3, ClaimGate::SEATS
      end
    end
  end
end
