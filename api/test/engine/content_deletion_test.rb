require "test_helper"
require_relative "entries/accounts_support"

class ContentDeletionTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "task deletion blanks each content column and keeps all other fields and neighboring content" do
    project = project_with_brief
    target = task_with_content(scenario, project)
    neighbor = task_with_content(scenario, project)
    other_workspace = Scenario.new
    remote = task_with_content(other_workspace, project_with_brief(other_workspace))
    unchanged = neighbor.keys + remote.keys + [ project, BriefEntry.find_by!(project_id: project.id) ]
    before = snapshot(target.keys + unchanged)

    written = events_written { assert_completed owner_command("delete_content", { task_id: target.keys.first.id }) }

    assert_equal [ "content.deleted" ], written.map(&:type)
    deleted_at = written.first.at
    target.each do |row, columns|
      expected = before.fetch(row).merge(columns.index_with(nil))
      expected["content_deleted_at"] = deleted_at if row.is_a?(Task)
      assert_equal expected, row.reload.attributes, "#{row.class} keeps every non-content field"
    end
    assert_equal before.slice(*unchanged), snapshot(unchanged)
  end

  test "task deletion removes its claim inputs while retaining the command key" do
    task = scenario.task(state: "done")
    other_task = scenario.task(state: "done")
    seat = own_seat(role: "orchestrator")
    requested = [ task, other_task ].map do |item|
      Command.create!(workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
        command: "claim_job", key: new_key, request_hash: "a" * 64, outcome: "completed",
        result: { "job_id" => SecureRandom.uuid, "input" => { "task_id" => item.id, "material" => "Made-up content" } })
    end
    target, neighbor = requested
    before = target.reload.attributes
    other_before = neighbor.reload.attributes

    assert_completed owner_command("delete_content", { task_id: task.id })

    expected = before.merge("result" => before.fetch("result").except("input"))
    assert_equal expected, target.reload.attributes
    assert_equal other_before, neighbor.reload.attributes
  end

  test "deletion clears copies in builder and reviewer claims and in claims from a former project" do
    project = scenario.project
    task = scenario.task(state: "done", project: project)
    claim = saved_claim("claim", own_seat(role: "builder"), "task" => { "id" => task.id, "title" => "Sample title" },
      "briefing" => { "brief" => "Sample brief" }, "work_reference" => "Sample path")
    review_identity = { "id" => SecureRandom.uuid, "task_id" => task.id }
    review = saved_claim("claim_review", own_seat(role: "reviewer"),
      "review" => review_identity.merge("notes" => "Sample notes"),
      "briefing" => { "brief" => "Sample brief" }, "work_reference" => "Sample path")
    outside = scenario.task(state: "working")
    old_project_claim = saved_claim("claim_job", own_seat(role: "orchestrator"),
      "job_id" => SecureRandom.uuid, "input" => { "task_id" => outside.id, "project_id" => project.id, "material" => "Sample brief" })

    assert_completed owner_command("delete_content", { project_id: project.id })

    assert_equal({ "task" => { "id" => task.id } }, claim.reload.result)
    assert_equal({ "review" => review_identity }, review.reload.result)
    refute old_project_claim.reload.result.key?("input")
    [ claim, review, old_project_claim ].each do |receipt|
      assert_equal "not_eligible", Leverage::Idempotency.outcome_of(receipt).refusal&.code
    end
  end

  test "deletion appends under the stepped-back clock and keeps replay, event history, and steps intact" do
    task = scenario.task(state: "done", project: scenario.project, details: "Made-up detail")
    before_events = Event.where(workspace_id: scenario.workspace_id).order(:seq).map(&:attributes)
    before_steps = step_snapshot
    assert_empty Leverage::Replay.diff(scenario.workspace_id)

    # Like ClockStepBackTest, make the clock read earlier than the last event.
    lock = Leverage::WorkspaceLock
    original_clock = lock.method(:clock)
    last_at = before_events.last.fetch("at")
    lock.define_singleton_method(:clock) { last_at - 0.040 }
    written = events_written { assert_completed owner_command("delete_content", { task_id: task.id }) }

    assert_equal [ "content.deleted" ], written.map(&:type)
    event = written.first
    assert_operator event.at, :>, last_at
    assert_equal event.at, task.reload.content_deleted_at
    assert_equal before_events, Event.where(workspace_id: scenario.workspace_id, seq: ..before_events.last.fetch("seq"))
      .order(:seq).map(&:attributes)
    assert_equal before_steps, step_snapshot
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
  ensure
    lock.define_singleton_method(:clock, original_clock) if original_clock
  end

  test "project deletion blanks its own content and each undeleted terminal task in event order" do
    project = project_with_brief
    already = scenario.task(state: "done", project: project)
    assert_completed owner_command("delete_content", { task_id: already.id })
    kept = already.reload.attributes
    done = scenario.task(state: "done", project: project)
    cancelled = scenario.task(state: "cancelled", project: project)
    criterion = Criterion.find_by!(task_id: done.id, kind: "build")
    outside = scenario.task(state: "done", project: project_with_brief)
    outside_before = outside.attributes
    brief = BriefEntry.find_by!(project_id: project.id)
    project_before = project.reload.attributes
    brief_before = brief.attributes
    before_steps = step_snapshot
    assert_empty Leverage::Replay.diff(scenario.workspace_id)

    key = new_key
    written = events_written { assert_completed owner_command("delete_content", { project_id: project.id }, key: key) }

    targets = [ [ nil, nil ] ] + [ done, cancelled ].sort_by(&:id).map { |task| [ task.id, task.round ] }
    assert_equal targets, written.map { |event| [ event.task_id, event.round ] }
    written.each do |event|
      assert_equal [ "content.deleted", project.id, "owner", scenario.owner.id, key, nil, nil, nil, {} ],
        [ event.type, event.project_id, event.actor_kind, event.actor_id, event.command_id,
          event.subject_kind, event.subject_id, event.cause_id, event.payload ]
    end
    assert_equal project_before.merge("name" => nil, "goal" => nil, "content_deleted_at" => written.first.at),
      project.reload.attributes
    assert_equal brief_before.merge("text" => nil), brief.reload.attributes
    [ done, cancelled ].each do |task|
      assert_nil task.reload.title
      assert_equal written.first.at, task.content_deleted_at
    end
    assert_nil criterion.reload.text
    assert_equal kept, already.reload.attributes
    assert_equal outside_before, outside.reload.attributes
    assert_equal before_steps, step_snapshot
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
  end

  private

  def saved_claim(command, seat, result)
    Command.create!(workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id, command: command,
      key: new_key, request_hash: "a" * 64, outcome: "completed", result: result)
  end

  def snapshot(rows) = rows.to_h { |row| [ row, row.reload.attributes ] }

  def step_snapshot = TaskStep.where(workspace_id: scenario.workspace_id).order(:id).map(&:attributes)

  def project_with_brief(world = scenario)
    world.project(goal: "Made-up project goal", budget: 42, brief: [ { kind: "decision", text: "Made-up brief" } ])
  end

  def task_with_content(world, project)
    task = world.task(state: "in_review", project: project, details: "Made-up detail",
      actions: [ { description: "Made-up action" } ])
    builder = Seat.find(task.builder_seat_id)
    review = Review.find_by!(task_id: task.id)
    review.update!(handoff_note: "Made-up handoff", notes: "Made-up note")
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    evidence = Evidence.create!(workspace_id: world.workspace_id, criterion_id: criterion.id, kind: "note",
      value: "Made-up evidence", attached_by_seat_id: builder.id)
    question = world.question(task, outcome: "answered", asking_seat: builder, blocking: false,
      assumption: "A made-up assumption", basis: "record")
    hold = world.hold(task, reason: "owner_hold")
    completed = owner_command("cancel", { id: task.id }, scenario: world)
    assert_completed completed
    hold.update!(detail: "Made-up hold detail")
    action = Action.find_by!(task_id: task.id)
    check = world.rule_check(task.reload, rule: world.rule, result: "passed", reason: "Made-up reason")
    check.update!(override_reason: "Made-up override reason")
    job = Job.find_by!(target_id: check.id)
    job.update!(input: { text: "Made-up input" }, result: { text: "Made-up result" })
    pending = world.pending_transition(task, command: "edit_contract", requester: world.owner,
      params: { title: "Made-up request" })
    {
      task => %w[title goal details work_reference], review => %w[handoff_note notes],
      criterion => %w[text], evidence => %w[value], question => %w[text assumption answer], action => %w[description],
      hold => %w[detail], check => %w[reason override_reason], job => %w[input result], pending => %w[params]
    }
  end
end
