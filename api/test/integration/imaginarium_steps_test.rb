require "test_helper"
require_relative "../engine/entries/jobs_support"

# The steps of a task that began as an Imaginarium idea (FR-039; PRD, Steps
# and timing). Add task writes the idea's criteria and lists them on
# task.created. After Promote, Complete contract keeps or resets them by
# position and kind, so task.contract_changed names none of them as added,
# and the step tracker has to read them from task.created.
class ImaginariumStepsTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    Leverage::Timers.apply_workspace(scenario.workspace, "install_imaginarium_project", at: scenario.database_now)
    @builder = scenario.seat(role: "builder", provider: "claude", last_polled_at: scenario.database_now)
    @reviewer = scenario.seat(role: "reviewer", provider: "codex", last_polled_at: scenario.database_now)
    @setup_seq = scenario.workspace.reload.last_seq
  end

  test "a promoted idea sent unchanged builds each criterion and is reviewed against its review criterion" do
    task = promoted_idea
    changed = events_written { send_contract(task, checks) }.find { |event| event.type == "task.contract_changed" }
    assert_empty changed.payload.fetch("added_criterion_ids"), "the idea's criteria are kept, not added"
    first, second = build_criteria(task)
    review_criterion = Criterion.find_by!(task_id: task.id, kind: "review")

    claim_and_acknowledge(task)
    assert_equal [ "build", nil ], open_step(task), "a builder criterion is still open"
    start_and_pass(task, first)
    assert_equal [ "build", first.id ], open_step(task)
    assert_completed(seat_command(@builder, "start_criterion", { "id" => task.id, "cid" => second.id }))
    assert_equal [ "build", second.id ], open_step(task)
    assert_completed(seat_command(@builder, "pass_criterion", { "id" => task.id, "cid" => second.id, "evidence" => evidence }))
    assert_equal [ "finish", nil ], open_step(task), "finish opens once every builder criterion has passed"
    assert_completed(seat_command(@builder, "submit", { "id" => task.id, "work_reference" => nil, "handoff_note" => "Made-up note." }))
    assert_completed(seat_command(@reviewer, "claim_review"))

    assert_equal [ "review", review_criterion.id ], open_step(task)
    assert_equal [ first.id, second.id ].sort,
      TaskStep.where(task_id: task.id, kind: "build", subject_kind: "criterion").pluck(:subject_id).uniq.sort
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: @setup_seq), "the log audit, after the seats' setup"
  end

  test "a promoted idea whose check the owner reworded still opens build" do
    task = promoted_idea
    reworded = checks.tap { |criteria| criteria.first["text"] = "It opens on the owner's Mac." }
    changed = events_written { send_contract(task, reworded) }.find { |event| event.type == "task.contract_changed" }
    assert_empty changed.payload.fetch("added_criterion_ids"), "a reworded criterion keeps its id"

    claim_and_acknowledge(task)

    assert_equal [ "build", nil ], open_step(task)
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
  end

  private

  def checks
    [ { "text" => "It opens on the Mac.", "kind" => "build" },
      { "text" => "Tasks are kept.", "kind" => "build" },
      { "text" => "A second agent reviews the work", "kind" => "review" } ]
  end

  def evidence = { "kind" => "note", "value" => "A made-up note." }

  def promoted_idea
    added = assert_completed(owner_command("add_task", { "title" => "Pocket to-do", "details" => "A made-up checklist.",
      "state" => "ideas", "criteria" => checks, "imaginarium" => { "entry_id" => "pocket-to-do", "catalog_version" => 1 } }))
    task = Task.find(added.result.fetch("task_id"))
    assert_completed(owner_command("promote", { "id" => task.id }))
    task
  end

  def send_contract(task, criteria)
    assert_completed(owner_command("complete_contract", contract_body(title: "Pocket to-do", details: "A made-up checklist.",
      criteria: criteria).merge("id" => task.id)))
    assert_equal "ready", task.reload.state
  end

  def build_criteria(task) = Criterion.where(task_id: task.id, kind: "build").order(:position).to_a

  def claim_and_acknowledge(task)
    assert_completed(seat_command(@builder, "claim"))
    assert_completed(seat_command(@builder, "acknowledge_briefing",
      { "id" => task.id, "briefing_hash" => Leverage::Briefing.hash_for(task.reload, seat: @builder) }))
  end

  def start_and_pass(task, criterion)
    assert_completed(seat_command(@builder, "start_criterion", { "id" => task.id, "cid" => criterion.id }))
    assert_completed(seat_command(@builder, "pass_criterion", { "id" => task.id, "cid" => criterion.id, "evidence" => evidence }))
  end

  # The task's open step, as [ kind, subject_id ].
  def open_step(task)
    TaskStep.where(task_id: task.id, closed_at: nil).pluck(:kind, :subject_id).sole
  end
end
