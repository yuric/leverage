require "test_helper"
require_relative "../engine/entries/jobs_support"
require_relative "../support/old_step_tracker"
require Rails.root.join("db/migrate/20261125190000_rebuild_steps_of_promoted_ideas")

# The repair of the steps stored for a promoted Imaginarium idea before the
# step tracker read task.created's criteria (FR-039; PRD, Steps and timing,
# and "What the replay test rebuilds"). Such a task's stored rows no longer
# match the ones the log gives, so the replay test fails and a restore
# refuses the dump. Leverage::StepRepair rebuilds them from the log, the
# migration runs it once, and nothing else is touched.
class StepRepairTest < ActiveSupport::TestCase
  include JobsSupport
  include OldStepTracker

  setup do
    use_scenario
    Leverage::Timers.apply_workspace(scenario.workspace, "install_imaginarium_project", at: scenario.database_now)
    @builder = scenario.seat(role: "builder", provider: "claude", last_polled_at: scenario.database_now)
    @setup_seq = scenario.workspace.reload.last_seq
  end

  test "the rows stored the old way fail the replay, and the repair rebuilds them from the log" do
    idea, other = stored_the_old_way
    refute_empty Leverage::Replay.diff(scenario.workspace_id), "the old rows differ from the log's"
    kept = step_ids(other)
    events = Event.where(workspace_id: scenario.workspace_id).count

    assert_equal [ idea.id ], Leverage::StepRepair.call

    assert_equal [ "build", nil ], open_step(idea)
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: @setup_seq)
    assert_equal kept, step_ids(other), "a task that was never an idea keeps its rows"
    assert_equal events, Event.where(workspace_id: scenario.workspace_id).count, "the repair writes no event"
  end

  test "the repair leaves rows that already match the log as they are" do
    idea = promoted_idea_at_its_first_step
    stored = step_ids(idea)

    assert_empty Leverage::StepRepair.call

    assert_equal stored, step_ids(idea)
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
  end

  test "the migration repairs the rows stored the old way" do
    stored_the_old_way
    refute_empty Leverage::Replay.diff(scenario.workspace_id)

    ActiveRecord::Migration.suppress_messages { RebuildStepsOfPromotedIdeas.new.migrate(:up) }

    assert_empty Leverage::Replay.diff(scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: @setup_seq)
  end

  test "the migration is the one the restore looks for" do
    assert_equal Leverage::StepRepair::MIGRATION,
      File.basename(RebuildStepsOfPromotedIdeas.instance_method(:up).source_location.first)[/\A\d+/]
  end

  private

  def checks
    [ { "text" => "It opens on the Mac.", "kind" => "build" },
      { "text" => "Tasks are kept.", "kind" => "build" },
      { "text" => "A second agent reviews the work", "kind" => "review" } ]
  end

  # A promoted idea whose briefing the builder acknowledged, and a task
  # that was never an idea, with the rows the tracker wrote before it read
  # task.created's criteria: finish where build belongs.
  def stored_the_old_way
    idea = other = nil
    with_the_old_step_tracker do
      idea = promoted_idea_at_its_first_step
      other = Task.find(assert_completed(owner_command("add_task", { "title" => "Made-up task", "state" => "backlog" }))
        .result.fetch("task_id"))
    end
    assert_equal [ "finish", nil ], open_step(idea), "the old tracker saw no criteria"
    [ idea, other ]
  end

  def promoted_idea_at_its_first_step
    added = assert_completed(owner_command("add_task", { "title" => "Pocket to-do", "details" => "A made-up checklist.",
      "state" => "ideas", "criteria" => checks, "imaginarium" => { "entry_id" => "pocket-to-do", "catalog_version" => 1 } }))
    task = Task.find(added.result.fetch("task_id"))
    assert_completed(owner_command("promote", { "id" => task.id }))
    assert_completed(owner_command("complete_contract", contract_body(title: "Pocket to-do", details: "A made-up checklist.",
      criteria: checks).merge("id" => task.id)))
    assert_completed(seat_command(@builder, "claim"))
    assert_completed(seat_command(@builder, "acknowledge_briefing",
      { "id" => task.id, "briefing_hash" => Leverage::Briefing.hash_for(task.reload, seat: @builder) }))
    task
  end

  def open_step(task) = TaskStep.where(task_id: task.id, closed_at: nil).pluck(:kind, :subject_id).sole

  def step_ids(task) = TaskStep.where(task_id: task.id).order(:opened_at, :id).pluck(:id)
end
