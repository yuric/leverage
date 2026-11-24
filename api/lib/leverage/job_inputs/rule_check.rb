module Leverage
  module JobInputs
    # The frozen rule and task material for a rule check (RD-30, RD-31).
    module RuleCheck
      # The label each hashed input's task text is quoted under (QuotedText),
      # by hook, in hooks.json's order of hashed inputs.
      QUOTED = {
        "task.before_claim" => %w[agent],
        "task.before_submit" => %w[evidence handoff_note],
        "task.before_done" => %w[review_notes evidence]
      }.freeze

      module_function

      def call(job, task)
        check = ::RuleCheck.find_by!(id: job.target_id, workspace_id: job.workspace_id)
        version = RuleVersion.find_by!(id: check.rule_version_id, workspace_id: job.workspace_id)
        pending = check.pending_transition_id &&
          PendingTransition.find_by(id: check.pending_transition_id, workspace_id: job.workspace_id)
        params = pending&.params.presence || job.input.to_h["params"] || {}
        seat = check.subject_kind == "seat" ? Seat.find_by(id: check.subject_id, workspace_id: job.workspace_id) : nil
        review = check.subject_kind == "review" ? Review.find_by(id: check.subject_id, workspace_id: job.workspace_id) : nil
        if seat.nil? && pending&.requester_kind == "seat"
          seat = Seat.find_by(id: pending.requester_id, workspace_id: job.workspace_id)
        end
        {
          "rule_check_id" => check.id, "attempt_number" => attempt_number(job, check), "rule_version_id" => version.id,
          "hook" => check.hook, "task_id" => task.id, "project_id" => task.project_id,
          "inputs" => job.input.to_h["inputs"].presence ||
            HookInputs.for(hook: check.hook, task: task, params: params, seat: seat, review: review),
          "material" => {
            "instruction" => version.instruction.to_s,
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
            "criteria" => JobInputs.live_criteria(task).map { |criterion| { "text" => criterion.text.to_s, "kind" => criterion.kind,
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
        ids = JobInputs.live_criteria(task).map(&:id)
        by_criterion = Evidence.where(criterion_id: ids).order(:created_at, :id).group_by(&:criterion_id)
        ids.flat_map { |id| by_criterion.fetch(id, []).map { |evidence| evidence.value.to_s } }
      end

      private_class_method :attempt_number, :moment, :check_contract, :quoted, :quote, :agent_text, :evidence_values
    end
  end
end
