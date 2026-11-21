require_relative "rules_test_support"

module Leverage
  module Rules
    # Rules::EvaluationBuilder (PRD L360-L368, L408-L423; milestone 4 plan
    # §2.1 rules 1 to 8): steps 2 to 5 of How a transition is gated for one
    # request, as an Evaluation the gate writes. It reads and plans only.
    class EvaluationBuilderTest < ActiveSupport::TestCase
      include TestSupport

      def evaluate(request) = EvaluationBuilder.call(request)

      def ready_request(task, kinds = %w[build review], requester: nil)
        request_for(task, "task.before_ready", params: contract_params(kinds), requester: requester)
      end

      def submit_request(task, note = "A made-up note.")
        request_for(task, "task.before_submit", params: { "handoff_note" => note }, requester: Seat.find(task.holder_seat_id))
      end

      def identity(check)
        [ check.rule_version_id, check.hook, check.round, check.subject_kind, check.subject_id, check.input_hash ]
      end

      test "a hook with no rule completes with nothing planned" do
        evaluation = evaluate(ready_request(scenario.task))

        assert_equal :completed, evaluation.outcome
        assert_equal [ [] ] * 8, evaluation.to_h.except(:outcome).values
      end

      test "the shipped gates at ready to start: the app check passes in the request, the model check is queued and the command waits" do
        rules = scenario.with_shipped_rules
        request = ready_request(scenario.task)
        evaluation = evaluate(request)
        criteria, details = rules.first(2).map { |rule| scenario.current_version(rule) }
        hash = Leverage::Gating.input_hash(hook: "task.before_ready", inputs: request.inputs)

        assert_equal :pending, evaluation.outcome
        assert_equal [ criteria.id, details.id ], evaluation.frozen_rule_version_ids
        assert_equal [ [ criteria.id, "app", "passed" ], [ details.id, "model", nil ] ],
          evaluation.checks.map { |check| [ check.rule_version_id, check.checker, check.result ] }
        assert_equal [ [ "rule_check", 1, "orchestrator" ] ], evaluation.jobs.map { |job| [ job.kind, job.rule_check_ref, job.seat_role ] }
        evaluation.checks.each { |check| assert_equal [ "task.before_ready", 0, nil, nil, hash ], identity(check).drop(1) }
        assert_empty evaluation.failures
        assert_empty evaluation.holds_to_open
      end

      test "a failed app gate at ready to start is a failure routed to the owner, with its reason on the row" do
        rules = scenario.with_shipped_rules(off: [ "specific_details" ])
        evaluation = evaluate(ready_request(scenario.task, %w[review]))

        assert_equal :completed, evaluation.outcome
        assert_equal [ "failed" ], evaluation.checks.map(&:result)
        failure = evaluation.failures.sole
        assert_equal [ rules.first.id, 0, "owner" ], [ failure.rule_id, failure.rule_check_ref, failure.route ]
        assert_equal "The contract has 0 acceptance criteria besides the review; this rule needs at least 1.", failure.reason
        assert_equal failure.reason, evaluation.checks.first.reason
      end

      test "a warn gate's failure is a warning, and a warn model gate queues its job and lets the command through (RC-16)" do
        app_gate("task.before_ready", "minimum_criteria_count", on_fail: "warn")
        model_gate("task.before_ready", on_fail: "warn", route: "owner")
        evaluation = evaluate(ready_request(scenario.task, %w[review]))

        assert_equal :completed, evaluation.outcome
        assert_empty evaluation.failures
        assert_equal 1, evaluation.warnings.size
        assert_equal [ "rule_check" ], evaluation.jobs.map(&:kind)
      end

      test "a gate whose fixed scope does not cover the task has a not_applicable row and nothing else (L364)" do
        model_gate("task.before_ready", scope_kind: "named_projects", scope_values: [ scenario.project.id ])
        evaluation = evaluate(ready_request(scenario.task))

        assert_equal :completed, evaluation.outcome
        assert_equal [ "not_applicable" ], evaluation.checks.map(&:result)
        assert_empty evaluation.jobs
      end

      test "moving a task into a named projects scope runs its gate on the same inputs" do
        project = scenario.project
        task = scenario.task(state: "ready")
        seat = scenario.seat
        rule = model_gate("task.before_claim", scope_kind: "named_projects", scope_values: [ project.id ])
        request = request_for(task, "task.before_claim", subject: seat, requester: seat)
        input_hash = Gating.input_hash(hook: request.hook, inputs: request.inputs)
        scenario.rule_check(task, rule: rule, subject: seat, result: "not_applicable", input_hash: input_hash)

        task.update!(project_id: project.id)
        evaluation = evaluate(request_for(task, "task.before_claim", subject: seat, requester: seat))

        assert_equal :pending, evaluation.outcome
        assert_equal [ "rule_check" ], evaluation.jobs.map(&:kind)
        assert_equal [ input_hash ], evaluation.checks.map(&:input_hash)
      end

      test "a let-the-checker-decide rule goes to the checker in the same job (L366)" do
        model_gate("task.before_ready", scope_kind: "checker_decides", route: "owner")
        evaluation = evaluate(ready_request(scenario.task))

        assert_equal :pending, evaluation.outcome
        assert_equal [ nil ], evaluation.checks.map(&:result)
        assert_equal [ "rule_check" ], evaluation.jobs.map(&:kind)
      end

      test "a stored passed result plans nothing" do
        rule = model_gate("task.before_submit")
        task = scenario.task(state: "working")
        request = submit_request(task)
        scenario.rule_check(task, rule: rule, result: "passed", input_hash: hash_for(task, "task.before_submit",
          params: { "handoff_note" => "A made-up note." }))

        evaluation = evaluate(request)
        assert_equal :completed, evaluation.outcome
        assert_equal [ [] ] * 7, evaluation.to_h.except(:outcome, :frozen_rule_version_ids).values
      end

      test "a stored failure is a failure that names the stored row and plans no row; an overridden one is cleared" do
        rule = model_gate("task.before_submit")
        task = scenario.task(state: "working")
        request = submit_request(task)
        stored = scenario.rule_check(task, rule: rule, result: "failed", reason: "A made-up reason.",
          input_hash: Leverage::Gating.input_hash(hook: "task.before_submit", inputs: request.inputs))

        evaluation = evaluate(request)
        assert_equal :completed, evaluation.outcome
        assert_empty evaluation.checks
        assert_empty evaluation.jobs
        failure = evaluation.failures.sole
        assert_equal [ rule.id, stored.id, "A made-up reason.", "builder" ],
          [ failure.rule_id, failure.rule_check_ref, failure.reason, failure.route ]

        override(stored)
        evaluation = evaluate(request)
        assert_equal :completed, evaluation.outcome
        assert_equal [ [], [], [] ], [ evaluation.checks, evaluation.failures, evaluation.jobs ]
      end

      test "an error, or a withdrawn check, is run again as a new attempt of the same row (DB-25)" do
        rule = model_gate("task.before_submit")
        %w[error withdrawn].each do |result|
          task = scenario.task(state: "working")
          request = submit_request(task)
          stored = scenario.rule_check(task, rule: rule, result: result,
            input_hash: Leverage::Gating.input_hash(hook: "task.before_submit", inputs: request.inputs))

          evaluation = evaluate(request)
          assert_equal :pending, evaluation.outcome, result
          check = evaluation.checks.sole
          assert_equal [ stored.rule_version_id, stored.hook, stored.round, stored.subject_kind, stored.subject_id,
                         stored.input_hash ], identity(check), result
          assert_nil check.result
          assert_equal [ [ "rule_check", 0 ] ], evaluation.jobs.map { |job| [ job.kind, job.rule_check_ref ] }, result
        end
      end

      test "a warn rule's row still running is left to finish: no row, no second job, the command goes on (rule 4)" do
        rule = model_gate("task.before_ready", on_fail: "warn", route: "owner")
        task = scenario.task
        request = ready_request(task)
        scenario.rule_check(task, rule: rule, input_hash: Leverage::Gating.input_hash(hook: "task.before_ready",
          inputs: request.inputs))

        evaluation = evaluate(request)
        assert_equal :completed, evaluation.outcome
        assert_empty evaluation.checks
        assert_empty evaluation.jobs
      end

      test "the run on a fourth distinct input plans a row with no job, a rerun_limit hold naming it, and waits (RD-45)" do
        rule = model_gate("task.before_submit")
        task = scenario.task(state: "working")
        3.times { |index| scenario.rule_check(task, rule: rule, result: "failed", input_hash: (index + 1).to_s * 64) }

        evaluation = evaluate(submit_request(task, "A fourth made-up note."))
        assert_equal :pending, evaluation.outcome
        assert_equal [ nil ], evaluation.checks.map(&:result)
        assert_empty evaluation.jobs
        hold = evaluation.holds_to_open.sole
        assert_equal [ "rerun_limit", rule.id, 0 ], [ hold.reason, hold.rule_id, hold.rule_check_id ]
      end

      test "an owner's contract change starts the count again (RD-46)" do
        rule = model_gate("task.before_submit")
        task = scenario.task(state: "working")
        3.times { |index| scenario.rule_check(task, rule: rule, result: "failed", input_hash: (index + 1).to_s * 64) }
        scenario.append("task.contract_changed", task: task, actor_kind: "owner", actor_id: scenario.owner.id,
          payload: { contract_version: 1, minimum_strength_rank: nil, added_criterion_ids: [], reset_criterion_ids: [],
                     removed_criterion_ids: [], added_action_ids: [], removed_action_ids: [] })

        evaluation = evaluate(submit_request(task, "A fourth made-up note."))
        assert_empty evaluation.holds_to_open
        assert_equal [ "rule_check" ], evaluation.jobs.map(&:kind)
      end

      test "at before an agent starts it, the third distinct seat failing an app gate plans claim_gate_failed (SM-19)" do
        rule = app_gate("task.before_claim", "minimum_criteria_count", parameters: { "minimum_count" => 5 }, route: "builder")
        task = scenario.task(state: "ready")
        seats = Array.new(4) { scenario.seat }
        failed = lambda do |seat, result|
          scenario.rule_check(task, rule: rule, result: result, subject: seat, input_hash: hash_for(task, "task.before_claim", subject: seat))
        end
        failed.call(seats[0], "failed")
        failed.call(seats[1], "error")

        evaluation = evaluate(request_for(task, "task.before_claim", subject: seats[2], requester: seats[2]))
        assert_equal [ "failed" ], evaluation.checks.map(&:result)
        assert_equal [ "builder" ], evaluation.failures.map(&:route)
        assert_empty evaluation.holds_to_open, "an errored check does not count"

        failed.call(seats[2], "failed")
        evaluation = evaluate(request_for(task, "task.before_claim", subject: seats[3], requester: seats[3]))
        hold = evaluation.holds_to_open.sole
        assert_equal [ "claim_gate_failed", rule.id, 0 ], [ hold.reason, hold.rule_id, hold.rule_check_id ]
      end

      test "the provider rule plans an applied row with effect refused for a reviewer it refuses, once per reviewer and round (RD-12)" do
        rule = scenario.with_shipped_rules.find { |row| row.key == "different_provider_review" }
        task = scenario.task(state: "in_review", builder: scenario.seat(credential: scenario.credential(provider: "claude")))
        refused = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude"))
        allowed = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "codex"))

        evaluation = evaluate(request_for(task, "review.assign", subject: refused, requester: refused))
        check = evaluation.checks.sole
        assert_equal [ "applied", "refused", "app", "seat", refused.id ],
          [ check.result, check.effect, check.checker, check.subject_kind, check.subject_id ]
        assert_equal [ [ rule.id, "review.assign", "refused" ] ], evaluation.effects.map { |effect| [ effect.rule_id, effect.hook, effect.effect ] }
        assert_equal :completed, evaluation.outcome

        quiet = evaluate(request_for(task, "review.assign", subject: allowed, requester: allowed))
        assert_equal [ [], [] ], [ quiet.checks, quiet.effects ]

        scenario.rule_check(task, rule: rule, result: "applied", effect: "refused", subject: refused,
          input_hash: hash_for(task, "review.assign", subject: refused))
        again = evaluate(request_for(task, "review.assign", subject: refused, requester: refused))
        assert_empty again.checks, "the row is unique per reviewer and round"
        assert_equal [ "refused" ], again.effects.map(&:effect)
      end

      test "with the provider rule off a reviewer is never refused" do
        scenario.with_shipped_rules(off: [ "different_provider_review" ])
        task = scenario.task(state: "in_review", builder: scenario.seat(credential: scenario.credential(provider: "claude")))
        reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude"))

        evaluation = evaluate(request_for(task, "review.assign", subject: reviewer, requester: reviewer))
        assert_equal [ [], [], [] ], [ evaluation.checks, evaluation.effects, evaluation.frozen_rule_version_ids ]
      end

      test "an app rule whose function is not built plans nothing at its hook (RD-8)" do
        app_gate("review.failed", "unbuilt")
        task = scenario.task(state: "in_review")
        review = Review.find_by!(task_id: task.id)

        evaluation = evaluate(request_for(task, "review.failed", subject: review, inputs: { "review_id" => review.id }))
        assert_equal :completed, evaluation.outcome
        assert_equal [ [] ] * 8, evaluation.to_h.except(:outcome).values
      end

      test "a rule with no route sends its failures to the owner at ready to start and to the builder elsewhere (RD-24)" do
        app_gate("task.before_ready", "minimum_criteria_count", route: nil)
        app_gate("task.before_submit", "minimum_criteria_count", parameters: { "minimum_count" => 5 }, route: nil)

        assert_equal [ "owner" ], evaluate(ready_request(scenario.task, %w[review])).failures.map(&:route)
        assert_equal [ "builder" ], evaluate(submit_request(scenario.task(state: "working"))).failures.map(&:route)
      end

      test "an unknown hook, or inputs that are not the hook's, is a mistake" do
        model_gate("task.before_submit")
        task = scenario.task(state: "working")

        assert_raises(ArgumentError) { evaluate(submit_request(task).with(hook: "task.before_lunch")) }
        assert_raises(ArgumentError) { evaluate(submit_request(task).with(inputs: { "handoff_note" => "x" })) }
      end
    end
  end
end
