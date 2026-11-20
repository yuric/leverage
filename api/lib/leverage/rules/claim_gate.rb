module Leverage
  module Rules
    # The claim gate's seats (PRD L393, L166; SM-19): a task that fails a
    # task.before_claim gate for SEATS different seats is held with
    # claim_gate_failed, because the rule is then about the task and not
    # the seat. A seat counts when it has a failed, not overridden check of
    # the rule for the task's current contract version and round; an
    # error does not count. It reads only.
    module ClaimGate
      # L393: 3 different seats. A constant of the PRD, not a setting
      # (milestone 4 plan §2.4).
      SEATS = 3

      HOOK = "task.before_claim".freeze

      module_function

      # The seats that failed the rule on the task's current contract
      # version and round, overrides left out.
      #
      # Returns an Array of seat ids.
      def failed_seat_ids(task, rule_id)
        RuleCheck.where(workspace_id: task.workspace_id, task_id: task.id, rule_id: rule_id, hook: HOOK, round: task.round,
          subject_kind: "seat", result: "failed", overridden_at: nil).pluck(:subject_id, :input_hash)
          .select { |seat_id, input_hash| input_hash == hash_for(task, seat_id) }.map(&:first).uniq
      end

      # Whether a failure of seat_id on the rule makes the task's SEATS-th
      # distinct seat, with no claim_gate_failed hold of the rule open.
      def reached?(task, rule_id, seat_id)
        return false if Hold.where(workspace_id: task.workspace_id, task_id: task.id, reason: "claim_gate_failed",
          rule_id: rule_id, closed_at: nil).exists?

        (failed_seat_ids(task, rule_id) | [ seat_id ]).size >= SEATS
      end

      # The input hash of a claim by seat_id on the task's current contract.
      def hash_for(task, seat_id)
        Gating.input_hash(hook: HOOK, inputs: { "contract_version" => task.contract_version, "seat_id" => seat_id })
      end
    end
  end
end
