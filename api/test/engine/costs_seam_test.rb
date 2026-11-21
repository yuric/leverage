require "test_helper"
require_relative "entries/jobs_support"

class CostsSeamTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @project = scenario.project
  end

  test "a passed review reports its cost once for the task and the project" do
    assert_review_cost(verdict: "passed", command: "pass_review", events: %w[review.passed task.done cost.reported])
  end

  test "a failed review reports its cost once for the round it reviewed" do
    assert_review_cost(verdict: "failed", command: "fail_review", events: %w[review.failed criterion.reopened cost.reported])
  end

  test "a contract draft result reports its cost once for the project" do
    task = scenario.task(state: "backlog", criteria: [], project: @project)
    planner = scenario.planner(provider: "claude")
    job = scenario.job(kind: "contract_draft", task: task, state: "claimed", seat: planner)
    params = result_params(job, contract_body, tokens: 80, spend: 0.125)

    events = assert_cost_call("submit_job_result", planner, params, task: task, subject: job)
    assert_equal %w[job.finished cost.reported task.contract_changed task.ready], events.map(&:type)
    assert_equal BigDecimal("0.125"), @project.reload.spent
    assert_equal BigDecimal("0"), task.reload.spent
  end

  private

  def assert_review_cost(verdict:, command:, events:)
    builder = scenario.seat(role: "builder")
    reviewer = scenario.seat(role: "reviewer")
    task = scenario.task(state: "in_review", builder: builder, project: @project)
    review = scenario.review(task, reviewer: reviewer)
    hash = Leverage::Briefing.hash_for(task, seat: reviewer, review: review)
    assert_completed(seat_command(reviewer, "acknowledge_review_briefing", { "id" => review.id, "briefing_hash" => hash }))
    failed = verdict == "failed" ? [ Criterion.find_by!(task_id: task.id, kind: "build").id ] : []
    params = { "id" => review.id, "verdict" => verdict, "notes" => "Made-up notes.", "failed_criteria" => failed,
               "tokens" => 80, "spend" => 0.125 }

    written = assert_cost_call(command, reviewer, params, task: task, subject: review)
    assert_equal events, written.map(&:type)
    assert_equal [ BigDecimal("0.125"), BigDecimal("0.125") ], [ task.reload.spent, @project.reload.spent ]
  end

  def assert_cost_call(command, seat, params, task:, subject:)
    calls = nil
    events = events_written do
      calls = spy_on(Leverage::Costs, :report) { assert_completed(seat_command(seat, command, params)) }
    end

    assert_equal 1, calls.size
    assert_equal({ task: task, subject: subject, tokens: 80, spend: 0.125 }, calls.sole.keywords)
    cost = events.select { |event| event.type == "cost.reported" }.sole
    assert_equal [ task.id, @project.id, 0, Leverage::EventLog.kind_of(subject), subject.id, "seat", seat.id ],
      cost.values_at(:task_id, :project_id, :round, :subject_kind, :subject_id, :actor_kind, :actor_id)
    assert_equal({ "tokens" => 80, "spend" => 0.125 }, cost.payload)
    events
  end
end
