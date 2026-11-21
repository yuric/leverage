module Leverage
  module Rules
    # What claim-next skips for one seat (RC-19, RC-50; milestone 4 plan
    # RD-12), read under the workspace lock by the claims and outside it by
    # GET /v1/next, both through Eligibility, so next never offers what the
    # claim would skip. It reads only.
    #
    #   tasks    those the seat failed a blocking task.before_claim gate on,
    #            on the current inputs (the task's contract version, its
    #            round, the rule's current version), and not overridden: a
    #            claim would reuse the stored failure (L421). An overridden
    #            failure is a task the seat may claim (RD-14 puts it first).
    #            Also skip tasks in projects at budget while the rule is on.
    #   reviews  those the provider rule keeps from the seat (RD-50).
    #
    # The tasks a seat ever held are left out of its reviews by Eligibility
    # itself (L455): that is built-in behaviour, not a rule, so a workspace
    # with no rule skips nothing here, as milestone 2's rule-free gating
    # did (RT-2).
    module ClaimFilter
      HOOK = "task.before_claim".freeze

      module_function

      # kind - :task or :review.
      #
      # Returns a Gating::ClaimFilter.
      def call(seat_id:, kind:)
        raise ArgumentError, "kind must be :task or :review, got #{kind.inspect}" unless %i[task review].include?(kind)

        seat = Seat.find_by(id: seat_id)
        tasks = seat && kind == :task ? failed_task_ids(seat) | budget_task_ids(seat) : []
        reviews = seat && kind == :review ? refused_review_ids(seat) : []
        Gating::ClaimFilter.new(excluded_task_ids: tasks, excluded_review_ids: reviews)
      end

      def failed_task_ids(seat)
        blocking = Catalog.at(seat.workspace_id, HOOK).map(&:version)
          .select { |version| version.on_fail == "block" }.index_by(&:id)
        return [] if blocking.empty?

        rows = RuleCheck.where(workspace_id: seat.workspace_id, hook: HOOK, subject_kind: "seat", subject_id: seat.id,
          result: "failed", overridden_at: nil, rule_version_id: blocking.keys)
          .pluck(:task_id, :round, :input_hash, :rule_version_id)
        tasks = Task.where(id: rows.map(&:first)).index_by(&:id)
        rows.filter_map do |task_id, round, input_hash, version_id|
          task = tasks[task_id]
          next unless task && round == task.round && input_hash == ClaimGate.hash_for(task, seat.id)

          task_id if Scope.covers?(blocking.fetch(version_id), task)
        end.uniq
      end

      def budget_task_ids(seat)
        policy = Catalog.at(seat.workspace_id, "cost.reported")
          .find { |entry| entry.version.checker_function == "pause_project_at_budget" }
        return [] unless policy

        projects = Checkers::PauseProjectAtBudget.projects_at_budget(seat.workspace_id)
        tasks = Task.where(workspace_id: seat.workspace_id, state: "ready", project_id: projects.select(:id))
        return tasks.ids if policy.version.scope_kind == "all_tasks"

        tasks.filter_map { |task| task.id if Scope.covers?(policy.version, task) }
      end

      def refused_review_ids(seat)
        reviews = Review.joins("JOIN tasks ON tasks.id = reviews.task_id AND tasks.round = reviews.round")
          .where(workspace_id: seat.workspace_id, verdict: nil, tasks: { state: "in_review" }).pluck(:id, :task_id)
        return [] if reviews.empty?

        provider = ProviderRule.review_provider(seat)
        allowed = reviews.map(&:last).uniq.to_h { |task_id| [ task_id, ProviderRule.allowed?(task_id, provider) ] }
        reviews.reject { |_, task_id| allowed.fetch(task_id) }.map(&:first)
      end

      private_class_method :failed_task_ids, :budget_task_ids, :refused_review_ids
    end
  end
end
