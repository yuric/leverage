module Leverage
  module Rules
    # The re-run limit (PRD L422; SM-35; milestone 4 plan RD-45, RD-46): a
    # model-checked gate runs at most the workspace's rerun_limit times per
    # round on changed inputs. It reads only.
    #
    # A run is a distinct input hash of one rule, hook, round and subject
    # whose check was queued (check.queued) since the owner last changed
    # the contract (the owner's latest task.contract_changed). A retry
    # after a timeout and a re-run on the same inputs are attempts of a
    # hash already counted; a row held at the limit was never queued and is
    # not a run. The count is per rule, not per version: a reworded rule
    # keeps counting. An owner's request at task.before_ready is itself a
    # change of the contract by the owner, so it starts the count again:
    # at "ready to start" only a planner's successive drafts can reach the
    # limit (RD-46).
    module RerunLimit
      module_function

      # The distinct input hashes run in the current count.
      #
      # Returns an Array of Strings.
      def runs(task:, rule_id:, hook:, round:, subject_kind:, subject_id:, owner_request: false)
        return [] if owner_request && hook == "task.before_ready"

        changed = Event.where(workspace_id: task.workspace_id, task_id: task.id, type: "task.contract_changed",
          actor_kind: "owner").maximum(:seq) || 0
        queued = Event.where(workspace_id: task.workspace_id, task_id: task.id, type: "check.queued")
          .where("seq > ?", changed).select(:subject_id)
        RuleCheck.where(workspace_id: task.workspace_id, task_id: task.id, rule_id: rule_id, hook: hook, round: round,
          subject_kind: subject_kind, subject_id: subject_id, id: queued).distinct.pluck(:input_hash)
      end

      # Whether a run on input_hash would be one more than the limit allows.
      def reached?(task:, rule_id:, hook:, round:, subject_kind:, subject_id:, input_hash:, owner_request: false)
        hashes = runs(task: task, rule_id: rule_id, hook: hook, round: round, subject_kind: subject_kind,
          subject_id: subject_id, owner_request: owner_request)
        !hashes.include?(input_hash) && hashes.size >= Workspace.where(id: task.workspace_id).pick(:rerun_limit)
      end
    end
  end
end
