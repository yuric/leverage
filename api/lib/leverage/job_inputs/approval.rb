module Leverage
  module JobInputs
    # The approval decision sees only the reviewed task's own material.
    module Approval
      module_function

      def call(job, task)
        check = ::RuleCheck.find_by!(id: job.target_id, workspace_id: task.workspace_id, task_id: task.id)
        action = Actions.for_task(task).find(check.subject_id)
        version = RuleVersion.find_by!(id: check.rule_version_id, workspace_id: task.workspace_id)
        criteria = JobInputs.live_criteria(task)
        contract = {
          "title" => task.title, "goal" => task.goal, "details" => task.details,
          "criteria" => criteria.map { |criterion| criterion.attributes.slice("text", "kind", "state") },
          "actions" => Actions.for_task(task).map { |definition| definition.attributes.slice("kind", "description") }
        }
        {
          "task_id" => task.id, "project_id" => task.project_id, "action_id" => action.id, "rule_check_id" => check.id,
          "material" => {
            "instruction" => instruction(version),
            "action" => action.attributes.slice("kind", "description", "position"),
            "contract" => contract, "quoted" => quotes(task, check.round, criteria)
          }
        }
      end

      def quotes(task, round, criteria)
        review = Review.find_by(workspace_id: task.workspace_id, task_id: task.id, round: round, verdict: "passed")
        evidence = Evidence.where(workspace_id: task.workspace_id, criterion_id: criteria.map(&:id))
          .order(:created_at, :id).group_by(&:criterion_id)
        values = [ [ "handoff_note", review&.handoff_note ], [ "review_notes", review&.notes ] ]
        criteria.each do |criterion|
          values.concat(evidence.fetch(criterion.id, []).map { |row| [ "evidence", row.value ] })
        end
        values.filter_map { |label, value| { "label" => label, "text" => value.to_s } unless value.nil? }
      end

      def instruction(version)
        value = version.instruction
        if value.nil? && version.origin == "shipped" && version.key == "orchestrator_approves_actions"
          value = Rules::Shipped.find(version.key).instruction
        end
        value.to_s
      end

      private_class_method :quotes, :instruction
    end
  end
end
