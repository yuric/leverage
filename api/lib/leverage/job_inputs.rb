module Leverage
  # Keeps each job's role file in its stored input and builds the rest of
  # the material at claim from its own task and project (AE-4, GA-2).
  module JobInputs
    BY_KIND = {
      "rule_check" => RuleCheck,
      "contract_draft" => ContractDraft,
      "approval" => Approval,
      "question" => Question
    }.freeze

    module_function

    # The input Jobs persists when queuing an attempt. This leaves the
    # original role file in place on a retry, including for a General claim.
    def store(input, role, kind:)
      return input unless BY_KIND.key?(kind)

      input = input.to_h
      material = input.fetch("material", {})
      role_file = material.fetch("role_file") { RoleFiles.text(role) }
      input.merge("material" => material.merge("role_file" => role_file, "job_rules" => []))
    end

    def for(job, seat: nil)
      task = Task.find_by!(id: job.task_id, workspace_id: job.workspace_id)
      builder = BY_KIND.fetch(job.kind) { raise ArgumentError, "no input is built for a #{job.kind} job in this milestone" }
      input = builder.call(job, task)
      role = seat&.role || job.seat_role
      role_file = if Roles.role_file?(role)
        job.input.to_h.fetch("material", {}).fetch("role_file") { RoleFiles.text(job.seat_role) }
      end
      material = input.fetch("material", {}).merge("role_file" => role_file, "job_rules" => Roles.job_rules(role))
      input.merge("material" => material)
    end

    # Rule checks and drafts use the same criteria in contract order.
    def live_criteria(task)
      Criterion.where(task_id: task.id, removed_at: nil).order(:position).to_a
    end
  end
end
