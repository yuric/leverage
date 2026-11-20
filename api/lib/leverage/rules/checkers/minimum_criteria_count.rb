module Leverage
  module Rules
    module Checkers
      # "Every task needs acceptance criteria" (PRD L436): passes when the
      # contract has at least minimum_count criteria of kind build, the
      # review criterion not counted. At task.before_ready the contract is
      # the requested one (the request's inputs); at another hook it is the
      # task's live criteria. Its reason names the count. It reads only.
      module MinimumCriteriaCount
        module_function

        def call(version:, request:, task:)
          minimum = Integer((version.parameters || {}).fetch("minimum_count", 1))
          count = build_count(request, task)
          AppCheckers::Result.new(result: count >= minimum ? "passed" : "failed", effect: nil,
            reason: "The contract has #{count} acceptance #{count == 1 ? "criterion" : "criteria"} besides the review; " \
                    "this rule needs at least #{minimum}.")
        end

        def build_count(request, task)
          if request.hook == "task.before_ready"
            Array(request.inputs["criteria"]).count { |criterion| criterion["kind"] == "build" }
          else
            Criterion.where(workspace_id: task.workspace_id, task_id: task.id, kind: "build", removed_at: nil).count
          end
        end

        private_class_method :build_count
      end
    end
  end
end
