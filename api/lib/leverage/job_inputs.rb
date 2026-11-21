module Leverage
  # Builds the contract input when the job is claimed, from that job's
  # own task and project (AE-4). Reads only.
  module JobInputs
    BY_KIND = {
      "rule_check" => RuleCheck,
      "contract_draft" => ContractDraft,
      "approval" => Approval,
      "question" => Question
    }.freeze

    module_function

    def for(job)
      task = Task.find_by!(id: job.task_id, workspace_id: job.workspace_id)
      input = BY_KIND.fetch(job.kind) { raise ArgumentError, "no input is built for a #{job.kind} job in this milestone" }
      input.call(job, task)
    end

    # Rule checks and drafts use the same criteria in contract order.
    def live_criteria(task)
      Criterion.where(task_id: task.id, removed_at: nil).order(:position).to_a
    end
  end
end
