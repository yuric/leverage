module Leverage
  module Rules
    # A stored rule check and what it means for a new request (PRD L408,
    # L421, L423; DB-25; milestone 4 plan §2.1 rule 4). A check is keyed by
    # task, rule version, hook, round, subject and input hash, nulls
    # matching nulls (index_rule_checks_identity). It reads only.
    #
    #   :cleared  overridden by the owner: a failed or errored check, or one
    #             held at the re-run limit; it no longer blocks (L423)
    #   :passed   passed or not_applicable: reused, nothing is planned
    #   :applied  a policy's row: reused with its effect
    #   :failed   failed and not overridden: a failure that names this row,
    #             with no new row (L421)
    #   :rerun    error or withdrawn: run again as a new attempt of this same
    #             row (DB-25: the planned check has this row's identity)
    #   :running  no result yet: a model check still being run, or a row
    #             held at the re-run limit; nothing more is planned for it
    #   nil       no row: nothing to reuse
    module StoredResults
      USES = {
        "passed" => :passed, "not_applicable" => :passed, "applied" => :applied,
        "failed" => :failed, "error" => :rerun, "withdrawn" => :rerun, nil => :running
      }.freeze

      module_function

      # The row of the identity, or nil.
      def find(task_id:, rule_version_id:, hook:, round:, subject_kind:, subject_id:, input_hash:)
        RuleCheck.find_by(task_id: task_id, rule_version_id: rule_version_id, hook: hook, round: round,
          subject_kind: subject_kind, subject_id: subject_id, input_hash: input_hash)
      end

      # What the row means for a new request with its identity.
      def use(row)
        return nil unless row
        return :cleared if row.overridden_at

        USES.fetch(row.result)
      end
    end
  end
end
