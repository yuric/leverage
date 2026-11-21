module Leverage
  module Rules
    # The rules of a briefing (PRD L470; RC-31; milestone 4 plan RD-8): every
    # rule that acts and whose fixed scope covers the task, with may_apply
    # false, and every "let the checker decide" rule, with may_apply true,
    # each with its current version. Rules that do not act yet, and rules
    # that are off or removed, are left out. A reviewer's briefing has the
    # same rules (RC-31): the seat and the review change nothing here. The
    # order is Catalog's. It reads only.
    module BriefingRules
      module_function

      # Returns an Array of Gating::BriefingPart of kind :rule.
      def call(task_id:, seat_id:, review_id: nil)
        task = Task.find_by!(id: task_id)
        Catalog.enabled(task.workspace_id).filter_map do |entry|
          next unless AppCheckers.acts?(entry.version)

          coverage = Scope.coverage(entry.version, task)
          next if coverage == :not_covered

          Gating::BriefingPart.new(kind: :rule, id: entry.rule.id, version: entry.rule.current_version,
            may_apply: coverage == :checker_decides)
        end
      end
    end
  end
end
