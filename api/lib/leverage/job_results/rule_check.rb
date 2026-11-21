module Leverage
  module JobResults
    # A rule check's verdict, followed by its cost and re-entry (RE-3, RE-8).
    module RuleCheck
      CHECK_RESULTS = %w[passed failed not_applicable].freeze

      module_function

      def check_shape(job, answer)
        unless CHECK_RESULTS.include?(answer["result"]) && answer["reason"].is_a?(String)
          raise Transitions::Invalid, "A rule check's result is passed, failed or not_applicable, with a reason."
        end
        return unless answer["result"] == "not_applicable"

        version = RuleVersion.find_by!(id: check_for(job).rule_version_id, workspace_id: job.workspace_id)
        unless version.scope_kind == "checker_decides"
          raise Transitions::Invalid, "Only a rule that lets the checker decide may not apply."
        end
      end

      def refusals(_task) = []

      def perform(ctx, job, task, seat:, answer:, tokens:, spend:)
        check = check_for(job)
        RuleChecks.finish(ctx, check, result: answer.fetch("result"), reason: answer.fetch("reason"), tokens: tokens, spend: spend)
        Costs.report(ctx, task: task, subject: job, tokens: tokens, spend: spend)
        CheckReentry.after(ctx, check, Gating::Trigger.new(kind: :check_finished, rule_check_id: check.id))
      end

      def check_for(job) = ::RuleCheck.find_by!(id: job.target_id, workspace_id: job.workspace_id)

      private_class_method :check_for
    end
  end
end
