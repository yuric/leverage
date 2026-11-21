module Leverage
  module Rules
    # Whether a rule version's fixed scope covers a task (PRD L334, L364;
    # plan RC-44; milestone 4 plan §2.1 rule 3). The server decides it at no
    # cost; "let the checker decide" goes to the checker, in the same job
    # (L366). It reads only.
    #
    #   all_tasks        every task
    #   named_projects   a task of one of the projects named (scope_values);
    #                    never a task with no project (RC-44)
    #   action_kinds     a task that ends in an outward action of one of the
    #                    kinds named: at task.before_ready the requested
    #                    contract's actions, elsewhere the task's actions
    #                    that are not waived or revoked
    #   checker_decides  the checker decides (a model rule); an app rule
    #                    cannot carry it (RD-6) and is treated as covering
    #
    # Milestone 4 offers only all_tasks and checker_decides (RD-22); the
    # other two are decided here all the same.
    module Scope
      # The action states in which a task no longer ends in that action.
      GONE = %w[waived revoked].freeze

      module_function

      # inputs - the request's hashed inputs, when the hook hashes the
      #          requested contract (task.before_ready); else nil.
      #
      # Returns :covers, :checker_decides or :not_covered.
      def coverage(version, task, inputs = nil)
        values = Array(version.scope_values)
        case version.scope_kind
        when "all_tasks" then :covers
        when "checker_decides" then version.checker == "model" ? :checker_decides : :covers
        when "named_projects" then task&.project_id && values.include?(task.project_id) ? :covers : :not_covered
        when "action_kinds" then (action_kinds(task, inputs) & values).empty? ? :not_covered : :covers
        else raise ArgumentError, "unknown scope #{version.scope_kind.inspect}"
        end
      end

      def covers?(version, task, inputs = nil)
        coverage(version, task, inputs) != :not_covered
      end

      def action_kinds(task, inputs)
        return Array(inputs["actions"]).map { |action| action["kind"] } if inputs.is_a?(Hash) && inputs.key?("actions")
        return [] unless task

        Action.where(workspace_id: task.workspace_id, task_id: task.id).where.not(state: GONE).pluck(:kind)
      end

      private_class_method :action_kinds
    end
  end
end
