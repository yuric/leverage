module Leverage
  # What a claimed job hands its seat (PRD L428, L429, L539; milestone 4
  # plan §2.3, RD-30, RD-31, RD-37, RE-2; RC-33): the contract's input of
  # the job's kind (RuleCheckJobInput, ContractDraftJobInput) with its
  # material, built when the job is claimed from the rows, never stored in
  # an event. Reads only.
  #
  # A rule check's material is everything its checker needs: the
  # orchestrator's role file, the frozen rule version's instruction, the
  # moment (hooks.json), whether "not applicable" is an answer (a "let the
  # checker decide" rule, L364), the contract it judges (at "ready to start"
  # the requested one from the pending transition's stored request, else the
  # task's current one) and the other task text the hook's inputs hold, each
  # under its frame label (plan §2.2), in the order the hook's hashed inputs
  # list them. A contract draft's is the planner's role file, the task's
  # title, goal and details, the criteria it already has, the three stored
  # values a planner may not change (RD-37) and its project's brief. Every
  # piece comes from the job's own task: nothing of another task is read.
  module JobInputs
    # The label each hashed input's task text is quoted under (QuotedText),
    # by hook, in hooks.json's order of hashed inputs.
    QUOTED = {
      "task.before_claim" => %w[agent],
      "task.before_submit" => %w[evidence handoff_note],
      "task.before_done" => %w[review_notes evidence]
    }.freeze

    module_function

    # The input of job, a Hash with string keys.
    def for(job)
      task = Task.find_by!(id: job.task_id, workspace_id: job.workspace_id)
      case job.kind
      when "rule_check" then rule_check(job, task)
      when "contract_draft" then contract_draft(job, task)
      else raise ArgumentError, "no input is built for a #{job.kind} job in this milestone"
      end
    end

    # --- a rule check -------------------------------------------------------

    def rule_check(job, task)
      check = RuleCheck.find_by!(id: job.target_id, workspace_id: job.workspace_id)
      version = RuleVersion.find_by!(id: check.rule_version_id, workspace_id: job.workspace_id)
      pending = check.pending_transition_id &&
        PendingTransition.find_by(id: check.pending_transition_id, workspace_id: job.workspace_id)
      params = pending&.params || {}
      seat = check.subject_kind == "seat" ? Seat.find_by(id: check.subject_id, workspace_id: job.workspace_id) : nil
      review = check.subject_kind == "review" ? Review.find_by(id: check.subject_id, workspace_id: job.workspace_id) : nil
      if seat.nil? && pending&.requester_kind == "seat"
        seat = Seat.find_by(id: pending.requester_id, workspace_id: job.workspace_id)
      end
      {
        "rule_check_id" => check.id, "attempt_number" => attempt_number(job, check), "rule_version_id" => version.id,
        "hook" => check.hook, "task_id" => task.id, "project_id" => task.project_id,
        "inputs" => HookInputs.for(hook: check.hook, task: task, params: params, seat: seat, review: review),
        "material" => {
          "role_file" => RoleFiles.text("orchestrator"), "instruction" => version.instruction.to_s,
          "moment" => moment(check.hook), "may_answer_not_applicable" => version.scope_kind == "checker_decides",
          "contract" => check_contract(check.hook, task, params),
          "quoted" => quoted(check.hook, task, params, seat, job.claimed_at || Time.current)
        }
      }
    end

    # The attempt the job runs: its rule_check_attempts row's number, else
    # the job's own.
    def attempt_number(job, check)
      RuleCheckAttempt.where(rule_check_id: check.id, job_id: job.id).pick(:attempt_number) || job.attempt_number
    end

    def moment(hook)
      Contract.hooks.fetch("hooks").find { |entry| entry.fetch("hook") == hook }.fetch("moment_name")
    end

    # The contract the check judges (CheckContract): at task.before_ready
    # the requested one (RE-2), else the task's.
    def check_contract(hook, task, params)
      if hook == "task.before_ready"
        criteria = Array(params["criteria"]).map { |criterion| criterion.to_h.stringify_keys }
        { "title" => (params["title"].presence || task.title).to_s, "goal" => params["goal"].to_s,
          "details" => params["details"],
          "criteria" => criteria.map { |criterion| { "text" => criterion["text"], "kind" => criterion["kind"], "state" => "open" } } }
      else
        { "title" => task.title.to_s, "goal" => task.goal.to_s, "details" => task.details,
          "criteria" => live_criteria(task).map { |criterion| { "text" => criterion.text.to_s, "kind" => criterion.kind,
                                                                 "state" => criterion.state } } }
      end
    end

    # The task text other than the contract the hook's inputs hold, each
    # piece under its label (QuotedText).
    def quoted(hook, task, params, seat, at)
      QUOTED.fetch(hook, []).flat_map do |label|
        case label
        when "agent" then seat ? [ quote(label, agent_text(seat, task, at)) ] : []
        when "evidence" then evidence_values(task).map { |value| quote(label, value) }
        when "handoff_note" then params["handoff_note"].nil? ? [] : [ quote(label, params["handoff_note"].to_s) ]
        when "review_notes" then params["notes"].nil? ? [] : [ quote(label, params["notes"].to_s) ]
        end
      end
    end

    def quote(label, text) = { "label" => label, "text" => text }

    # The claiming agent's provider and model: the provider of the account
    # its run would be on, and the model a run on it uses (HE-5); the
    # tool's own default when none is set. at is the claim's time.
    def agent_text(seat, task, at)
      credential = seat.credential_id && Candidates.first_available(seat, task, at)
      credential ||= seat.credential_id && Credential.find_by(id: seat.credential_id, workspace_id: seat.workspace_id)
      provider = credential&.provider || seat.provider
      model = Candidates.model_for(seat, credential) || "the tool's default"
      "Provider: #{provider}. Model: #{model}."
    end

    # Every live criterion's evidence values, by criterion position, each
    # in the order it was attached (as HookInputs hashes them).
    def evidence_values(task)
      ids = live_criteria(task).map(&:id)
      by_criterion = Evidence.where(criterion_id: ids).order(:created_at, :id).group_by(&:criterion_id)
      ids.flat_map { |id| by_criterion.fetch(id, []).map { |evidence| evidence.value.to_s } }
    end

    def live_criteria(task)
      Criterion.where(task_id: task.id, removed_at: nil).order(:position).to_a
    end

    # --- a contract draft -----------------------------------------------------

    def contract_draft(job, task)
      project = task.project_id && Project.find_by(id: task.project_id, workspace_id: job.workspace_id)
      {
        "task_id" => task.id, "project_id" => task.project_id, "brief_version" => project&.brief_version || 0,
        "material" => {
          "role_file" => RoleFiles.text("planner"), "title" => task.title.to_s, "goal" => task.goal.to_s,
          "details" => task.details,
          "criteria" => live_criteria(task).map { |criterion| { "text" => criterion.text.to_s, "kind" => criterion.kind } },
          "work_reference" => task.work_reference, "minimum_strength_rank" => task.minimum_strength_rank,
          "budget_cap" => task.budget_cap&.to_f, "brief" => brief(project)
        }
      }
    end

    # The project's brief entries (BriefEntry); none for a task with no
    # project, and none is written in this milestone.
    def brief(project)
      return [] unless project

      BriefEntry.where(project_id: project.id, workspace_id: project.workspace_id).order(:created_at, :id).map do |entry|
        { "id" => entry.id, "project_id" => entry.project_id, "kind" => entry.kind, "text" => entry.text.to_s,
          "author_kind" => entry.author_kind, "author_id" => entry.author_id }
      end
    end

    private_class_method :rule_check, :attempt_number, :moment, :check_contract, :quoted, :quote, :agent_text,
      :evidence_values, :live_criteria, :contract_draft, :brief
  end
end
