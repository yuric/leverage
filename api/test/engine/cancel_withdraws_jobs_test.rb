require "test_helper"
require_relative "entries/gated_flow_support"

# Cancel withdraws a task's pending checks and jobs (PRD L207, L115), not
# only those of a waiting command: a queued contract draft and a warn
# rule's check that no command waits on are withdrawn too, so no seat
# claims and runs model work for a cancelled task (milestone 4 review,
# finding 6). Jobs.claimable also never hands out a job of a task that has
# ended.
class CancelWithdrawsJobsTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup { use_scenario }

  def live_jobs(task) = Job.where(workspace_id: scenario.workspace_id, task_id: task.id, state: %w[queued claimed])

  test "cancel withdraws a queued contract draft, and the planner gets nothing" do
    planner = scenario.planner(credential: scenario.credential(provider: "codex", model: nil))
    task = scenario.task(state: "backlog", criteria: [])
    job = Job.find(assert_completed(owner_command("draft_contract", { "id" => task.id })).result.fetch("job_id"))

    written = events_written { assert_completed(owner_command("cancel", { "id" => task.id })) }

    assert_equal "withdrawn", job.reload.state
    assert_includes written.map { |event| [ event.type, event.subject_id ] }, [ "job.withdrawn", job.id ]
    assert_refused("not_eligible", claim_job(planner))
  end

  test "cancel withdraws a claimed contract draft" do
    planner = scenario.planner(credential: scenario.credential(provider: "codex", model: nil))
    task = scenario.task(state: "backlog", criteria: [])
    assert_completed(owner_command("draft_contract", { "id" => task.id }))
    job = Job.find(assert_completed(claim_job(planner)).result.fetch("job_id"))

    assert_completed(owner_command("cancel", { "id" => task.id }))

    assert_equal "withdrawn", job.reload.state
  end

  test "cancel withdraws a warn rule's queued check and its job" do
    orchestrator = online_orchestrator
    builder = scenario.seat(role: "builder")
    model_rule(hook: "task.before_submit", on_fail: "warn")
    task = ready_to_submit(builder)
    assert_completed(seat_command(builder, "submit", submit_body(task)))
    check = RuleCheck.find_by!(task_id: task.id)
    assert_nil check.result

    written = events_written { assert_completed(owner_command("cancel", { "id" => task.id })) }

    assert_equal "withdrawn", check.reload.result
    assert_empty live_jobs(task)
    finished = written.select { |event| event.type == "check.finished" && event.subject_id == check.id }
    assert_equal [ "withdrawn" ], finished.map { |event| event.payload["result"] }
    assert_refused("not_eligible", claim_job(orchestrator))
  end

  test "a job left queued on a cancelled task is never handed out" do
    orchestrator = online_orchestrator
    task = scenario.task(state: "cancelled")
    scenario.job(kind: "rule_check", task: task, target: scenario.rule_check(scenario.task(state: "backlog"),
      rule: model_rule))
    Job.where(workspace_id: scenario.workspace_id).update_all(task_id: task.id)

    assert_refused("not_eligible", claim_job(orchestrator))
  end
end
