require "test_helper"
require_relative "jobs_support"

# draft_contract (PRD L110, L802; milestone 4 plan RD-37, DB-31; trace 16
# command 9): the owner asks a planner to write a Backlog task's contract.
# A contract_draft job is queued for the planner role (job.queued), and the
# answer names it. Refused invalid_state outside Backlog and while a draft
# job of the task is queued or claimed; asked again after the last one
# ended, it queues a new one.
class DraftContractTest < ActiveSupport::TestCase
  include JobsSupport
  include OpenapiAssertions

  setup { use_scenario }

  def draft(task, key: new_key) = owner_command("draft_contract", { "id" => task.id }, key: key)

  test "trace 16 command 9: the owner's ask queues a contract draft for the planner and names the job" do
    project = scenario.project(brief_version: 3)
    task = scenario.task(state: "backlog", criteria: [], project: project)
    key = new_key
    outcome = nil
    written = events_written { outcome = assert_completed(draft(task, key: key)) }

    job = Job.find(outcome.result.fetch("job_id"))
    assert_matches_component("DraftContractResult", outcome.result)
    assert_equal [ "contract_draft", task.id, project.id, "task", task.id, "planner", "queued", 1 ],
      job.attributes.values_at("kind", "task_id", "project_id", "target_kind", "target_id", "seat_role", "state",
        "attempt_number")
    assert_equal({ "task_id" => task.id, "project_id" => project.id, "brief_version" => 3 }, job.input.except("material"))
    queued = written.sole
    assert_equal [ "job.queued", "job", job.id, task.id, "owner", scenario.owner.id, key, { "kind" => "contract_draft" } ],
      [ queued.type, queued.subject_kind, queued.subject_id, queued.task_id, queued.actor_kind, queued.actor_id,
        queued.command_id, queued.payload ]
    assert_equal "backlog", task.reload.state
  end

  test "a task with no project has brief version 0" do
    task = scenario.task(state: "backlog", criteria: [])
    job = Job.find(assert_completed(draft(task)).result.fetch("job_id"))

    assert_equal({ "task_id" => task.id, "project_id" => nil, "brief_version" => 0 }, job.input.except("material"))
  end

  test "outside Backlog it is invalid_state and nothing is queued" do
    %w[imaginarium ready working cancelled].each do |state|
      task = scenario.task(state: state)
      assert_refused("invalid_state", draft(task))
    end
    assert_equal 0, Job.where(workspace_id: scenario.workspace_id).count
  end

  test "while a draft of the task is queued or claimed it is invalid_state; after it ends, a new one is queued (RD-37)" do
    task = scenario.task(state: "backlog", criteria: [])
    assert_completed(draft(task))
    assert_refused("invalid_state", draft(task))

    planner = scenario.planner(provider: "claude")
    mine = Job.where(workspace_id: scenario.workspace_id)
    mine.sole.update!(state: "claimed", claimed_by_seat_id: planner.id, claimed_at: scenario.database_now)
    assert_refused("invalid_state", draft(task))

    mine.sole.update!(state: "timed_out")
    assert_completed(draft(task))
    assert_equal %w[queued timed_out], mine.order(:state).pluck(:state).sort
  end

  test "another task's draft does not stop this one" do
    scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"))

    assert_completed(draft(scenario.task(state: "backlog")))
  end

  test "a task outside the workspace is 404" do
    assert_raises(T::NotFound) { draft(Scenario.new.task(state: "backlog")) }
  end
end
