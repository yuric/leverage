require "test_helper"
require_relative "entries/jobs_support"

class CostsTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @builder = own_seat
    @project = scenario.project
    @task = scenario.task(state: "working", builder: @builder, project: @project)
    @task.update!(budget_cap: 1)
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new
  end

  test "a seat reports cost once and its report counts against the task and project" do
    req = seat_request(@builder, "report_cost", cost_params)
    events = events_written do
      assert_completed(T.apply(req))
      assert_completed(T.apply(req))
    end
    assert_equal %w[cost.reported], types(events)
    cost = events.sole
    assert_equal [ @task.id, @project.id, "seat", @builder.id, nil, nil ],
      cost.values_at(:task_id, :project_id, :actor_kind, :actor_id, :subject_kind, :subject_id)
    assert_equal({ "tokens" => 50, "spend" => 1 }, cost.payload)
    assert_equal [ 1, 1 ], [ @task.reload.spent, @project.reload.spent ]
  end

  test "spend that would overflow either total is invalid and keeps both totals and the log intact" do
    [ @task, @project ].each do |nearly_full|
      assert_completed(seat_command(@builder, "report_cost", cost_params.merge("spend" => 0)))
      nearly_full.update!(spent: 99_999_999.999999)
      before = [ @task.reload.spent, @project.reload.spent ]
      assert_empty events_written {
        assert_raises(T::Invalid) { seat_command(@builder, "report_cost", cost_params.merge("spend" => 0.000001)) }
      }
      assert_equal before, [ @task.reload.spent, @project.reload.spent ]
      nearly_full.update!(spent: 0)
    end
  end

  test "one report above the per-report maximum is invalid and writes nothing" do
    assert_empty events_written {
      assert_raises(T::Invalid) { seat_command(@builder, "report_cost", cost_params.merge("spend" => 100_000.000001)) }
    }
    assert_equal [ 0, 0 ], [ @task.reload.spent, @project.reload.spent ]

    planner = scenario.planner
    job = scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog", project: @project), state: "claimed",
      seat: planner)
    draft = { "title" => "A made-up task", "details" => "Made-up details.", "criteria" => [], "actions" => [] }
    assert_empty events_written {
      assert_raises(T::Invalid) { submit_result(planner, job, draft, spend: 100_000.000001) }
    }
  end

  test "one report of the per-report maximum leaves room for the project's later verdicts and reports" do
    assert_completed(seat_command(@builder, "report_cost", cost_params.merge("spend" => 100_000)))
    assert_equal [ 100_000, 100_000 ], [ @task.reload.spent, @project.reload.spent ]

    reviewer = own_seat(role: "reviewer")
    task = scenario.task(state: "in_review", project: @project)
    review = scenario.review(task, reviewer: reviewer)
    hash = Leverage::Briefing.hash_for(task, seat: reviewer, review: review)
    assert_completed(seat_command(reviewer, "acknowledge_review_briefing", { "id" => review.id, "briefing_hash" => hash }))
    assert_completed(seat_command(reviewer, "pass_review", { "id" => review.id, "verdict" => "passed",
      "notes" => "Sample review.", "failed_criteria" => [], "tokens" => 0, "spend" => 1 }))
    assert_equal "done", task.reload.state

    assert_completed(seat_command(@builder, "report_cost", cost_params))
    assert_equal [ 100_001, 100_002 ], [ @task.reload.spent, @project.reload.spent ]
  end

  test "a check can finish when its cost puts the waiting verdict over the project spending limit" do
    reviewer = own_seat(role: "reviewer")
    orchestrator = scenario.orchestrator
    task = scenario.task(state: "in_review", project: @project)
    review = scenario.review(task, reviewer: reviewer)
    scenario.rule(hook: "task.before_done")
    @project.update!(spent: 99_999_998.999999)
    Leverage::Gating.implementation = Leverage::Rules::Engine.new
    hash = Leverage::Briefing.hash_for(task, seat: reviewer, review: review)
    assert_completed(seat_command(reviewer, "acknowledge_review_briefing", { "id" => review.id, "briefing_hash" => hash }))
    verdict = { "id" => review.id, "verdict" => "passed", "notes" => "Sample review.",
      "failed_criteria" => [], "tokens" => 0, "spend" => 1 }
    key = new_key
    assert_equal :pending, seat_command(reviewer, "pass_review", verdict, key: key).outcome
    job = Job.find(assert_completed(claim_job(orchestrator)).result.fetch("job_id"))

    assert_completed(submit_result(orchestrator, job, { "result" => "passed", "reason" => "Sample reason." }, spend: 1))

    assert_equal "finished", job.reload.state
    assert_equal "invalid_state", Command.find_by!(key: key).refusal.fetch("code")
    assert_nil review.reload.verdict
    assert_equal BigDecimal("99999999.999999"), @project.reload.spent
    assert_completed(seat_command(reviewer, "pass_review", verdict.merge("spend" => 0)))
    assert_equal "done", task.reload.state
  end

  test "a seat can report under a hold without acknowledging while a submit waits on a check" do
    scenario.hold(@task, reason: "owner_hold")
    pending = scenario.pending_transition(@task, command: "submit", requester: @builder)

    events = events_written { assert_completed(seat_command(@builder, "report_cost", cost_params)) }

    assert_equal %w[cost.reported], types(events)
    assert_equal "pending", pending.reload.state
    assert_equal "owner_hold", open_hold(@task).reason
  end

  test "the post-report policy sees the updated sums and the cost event exactly once" do
    policy("task_held")
    gating = Leverage::Gating.implementation
    original = gating.method(:evaluate)
    request_fields = []
    gating.define_singleton_method(:evaluate) do |request|
      request_fields << [ request.subject_kind, request.subject_id, request.inputs, Task.find(request.task_id).spent,
                         Project.find(request.project_id).spent ]
      original.call(request)
    end
    events = events_written { assert_completed(seat_command(@builder, "report_cost", cost_params)) }

    assert_equal %w[cost.reported check.finished hold.opened inbox.opened], types(events)
    cost, check, hold, item = events
    assert_equal [ [ "event", cost.id, { "event_id" => cost.id }, 1, 1 ] ], request_fields
    assert_equal [ "applied", "task_held", "event", cost.id ],
      check.payload.values_at("result", "effect", "subject_kind", "subject_id")
    assert_equal [ "seat", @builder.id, cost.command_id ], check.values_at(:actor_kind, :actor_id, :command_id)
    assert_equal [ check.id, hold.id ], [ hold.cause_id, item.cause_id ]
    assert_equal "budget", open_hold(@task).reason
  end

  test "one policy check can apply a project pause and a task hold together" do
    @project.update!(budget: 1)
    rule = policy("project_paused")
    gating = Leverage::Gating.implementation
    original = gating.method(:evaluate)
    gating.define_singleton_method(:evaluate) do |request|
      evaluation = original.call(request)
      task_effect = Leverage::Gating::Effect.new(rule_id: rule.id, hook: request.hook, effect: "task_held")
      evaluation.with(effects: evaluation.effects + [ task_effect ])
    end

    events = events_written { assert_completed(seat_command(@builder, "report_cost", cost_params)) }

    assert_equal %w[cost.reported check.finished project.paused hold.opened inbox.opened hold.opened inbox.opened], types(events)
    assert_equal %w[project_paused budget], Leverage::Holds.open_holds(@task).map(&:reason)
    assert_equal [ @task.id, @project.id ].sort, InboxItem.where(state: "open", workspace_id: scenario.workspace_id).pluck(:about_id).sort

    later = events_written { assert_completed(seat_command(@builder, "report_cost", cost_params)) }
    assert_equal %w[cost.reported check.finished], types(later)
  end

  test "a job's report runs the project budget policy while leaving task spend and its cap alone" do
    @project.update!(budget: 2)
    @task.update!(spent: 1)
    job = scenario.job(kind: "contract_draft", task: @task)
    policy("project_paused")

    events = events_written { Leverage::Costs.report(scenario.context, task: @task, subject: job, tokens: 30, spend: 2) }

    assert_equal %w[cost.reported check.finished project.paused hold.opened inbox.opened], types(events)
    assert_equal [ "job", job.id, @project.id ], events.first.values_at(:subject_kind, :subject_id, :project_id)
    assert_equal [ 1, 2 ], [ @task.reload.spent, @project.reload.spent ]
    assert_equal [ "project_paused" ], Leverage::Holds.open_holds(@task).map(&:reason)
  end

  test "an existing budget hold is kept when the holder reports again" do
    policy("task_held")
    scenario.hold(@task, reason: "budget")

    events_written { assert_completed(seat_command(@builder, "report_cost", cost_params)) }

    assert_equal 1, Hold.where(task_id: @task.id, reason: "budget", closed_at: nil).count
    assert_equal 1, InboxItem.where(about_id: @task.id, kind: "task_budget_reached", state: "open").count
    assert_equal 1, @task.reload.spent
  end

  test "the budget effect cannot hold a task a verdict moved to Done" do
    rule = policy("task_held")
    reviewer = own_seat(role: "reviewer")
    task = scenario.task(state: "in_review", project: @project)
    review = scenario.review(task, reviewer: reviewer)
    task.update!(budget_cap: 1)
    hash = Leverage::Briefing.hash_for(task, seat: reviewer, review: review)
    assert_completed(seat_command(reviewer, "acknowledge_review_briefing", { "id" => review.id, "briefing_hash" => hash }))

    events = events_written do
      assert_completed(seat_command(reviewer, "pass_review", { "id" => review.id, "verdict" => "passed",
        "notes" => "Made-up notes.", "failed_criteria" => [], "tokens" => 50, "spend" => 1 }))
    end

    assert_equal %w[review.passed task.done cost.reported check.finished], types(events)
    assert_equal rule.id, events.last.payload.fetch("rule_id")
    assert_equal "done", task.reload.state
    assert_nil open_hold(task)
  end

  test "a cap that is equal to spend stays held through either cap writer" do
    @task.update!(spent: 1)
    hold = scenario.hold(@task, reason: "budget")
    events = events_written do
      assert_completed(owner_command("change_task_cap", { "id" => @task.id, "budget_cap" => 1 }))
      Leverage::Costs.cap_changed(scenario.context, @task.reload)
    end

    assert_equal %w[task.changed], types(events)
    assert_nil hold.reload.closed_at
  end

  test "clearing a cap through the command or raising it through the contract seam closes its hold" do
    @task.update!(spent: 1)
    hold = scenario.hold(@task, reason: "budget")
    events = events_written { assert_completed(owner_command("change_task_cap", { "id" => @task.id, "budget_cap" => nil })) }

    assert_equal %w[task.changed hold.closed inbox.resolved], types(events)
    assert_equal events.first.id, events.second.cause_id
    assert_equal "raise_cap", events.last.payload.fetch("choice")
    assert hold.reload.closed_at
    assert @task.reload.resume_pending_since

    @task.update!(budget_cap: 2)
    hold = scenario.hold(@task, reason: "budget")
    events = events_written { Leverage::Costs.cap_changed(scenario.context, @task) }

    assert_equal %w[hold.closed inbox.resolved], types(events)
    assert hold.reload.closed_at
  end

  test "the cap seam closes a hold when the cap is empty" do
    @task.update!(budget_cap: nil)
    hold = scenario.hold(@task, reason: "budget")

    Leverage::Costs.cap_changed(scenario.context, @task)

    assert hold.reload.closed_at
  end

  private

  def cost_params = { "id" => @task.id, "tokens" => 50, "spend" => 1 }

  def policy(effect)
    rule = scenario.rule(hook: "cost.reported", kind: "policy", checker: "app", checker_function: "pause_project_at_budget")
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(rules: [
      { id: rule.id, version_id: scenario.current_version(rule).id, version: 1, hook: "cost.reported", kind: "policy",
        checker: "app", enabled: true, effect: effect }
    ])
    rule
  end
end
