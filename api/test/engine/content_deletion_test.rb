require "test_helper"
require_relative "entries/accounts_support"
require_relative "gate_support"

class ContentDeletionTest < ActiveSupport::TestCase
  include AccountsSupport
  include GateSupport

  setup { use_scenario }

  %w[task project].each do |target|
    test "#{target} content deletion resolves the unanswered item on a Done task" do
      builder = own_seat
      task = ready_to_submit(builder)
      project = scenario.project if target == "project"
      assert_completed command("ask_question", builder, { "id" => task.id, "text" => "Which sample?",
        "assumption" => "The short one.", "blocking" => false })
      items = InboxItem.where(workspace_id: scenario.workspace_id, about_kind: "task", about_id: task.id)
      item = items.where(state: "open").sole
      assert_equal "question_passed_on", item.kind
      assert_nil item.hold_id

      assert_completed command("submit", builder, submit_params(task))
      if project
        assert_completed owner_command("change_task_project", { id: task.id, project_id: project.id })
      end
      task.reload
      reviewer = own_seat(role: "reviewer")
      review = scenario.review(task, reviewer: reviewer)
      assert_completed command("acknowledge_review_briefing", reviewer, { "id" => review.id,
        "briefing_hash" => Leverage::Briefing.hash_for(task, seat: reviewer, review: review) })
      assert_completed command("pass_review", reviewer, pass_params(review))
      assert_equal "done", task.reload.state
      assert_equal "open", item.reload.state

      other = scenario.question(scenario.task(state: "working", builder: builder), outcome: "passed_on", blocking: false)
      params = project ? { project_id: project.id } : { task_id: task.id }
      before = Event.where(workspace_id: scenario.workspace_id).order(:seq).last
      written = with_clock_behind(before.at) { events_written { assert_completed owner_command("delete_content", params) } }

      assert_empty items.where(state: "open")
      assert InboxItem.exists?(workspace_id: scenario.workspace_id, about_kind: "task", about_id: other.task_id, state: "open")
      expected = %w[inbox.resolved content.deleted]
      assert_equal expected, written.select { |event| event.task_id == task.id }.map(&:type)
      resolved = written.find { |event| event.type == "inbox.resolved" }
      assert_equal [ item.id, { "choice" => "cancel" } ], [ resolved.subject_id, resolved.payload ]
      assert_operator resolved.at, :>, before.at
      assert_equal [ "resolved", "owner", scenario.owner.id, resolved.at ],
        item.reload.attributes.values_at("state", "resolved_by_kind", "resolved_by_id", "resolved_at")
      assert_empty Leverage::Replay.diff(scenario.workspace_id)
      assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: before.seq)
    end
  end

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

  %w[app model].each do |checker|
    test "task deletion removes the #{checker} gate reason from command outcomes without changing another task" do
      builder = own_seat
      mark = "MADE-UP-GATE-CONTENT"
      rule = if checker == "app"
        app_rule("task.before_submit")
      else
        custom_rule("task.before_submit")
      end

      first = ready_to_submit(builder)
      second = ready_to_submit(own_seat)
      keys = [ first, second ].map do |task|
        reason = mark
        gating([ rule, { app_result: "failed", reason: reason } ]) if checker == "app"
        Leverage::Gating.implementation = Leverage::Rules::Engine.new if checker == "model"
        holder = Seat.find(task.holder_seat_id)
        outcome = command("submit", holder, submit_params(task))
        key = @key
        if checker == "model"
          assert_equal :pending, outcome.outcome
          orchestrator = scenario.orchestrator
          job_id = assert_completed(command("claim_job", orchestrator)).result.fetch("job_id")
          assert_completed(command("submit_job_result", orchestrator, { "id" => job_id, "tokens" => 0, "spend" => 0,
            "result" => { "result" => "failed", "reason" => reason } }))
        end

        refusal = command_receipt(holder, key).outcome.refusal
        assert_equal [ "blocked_by_rule", rule.id ], [ refusal.code, refusal.rule_id ]
        assert refusal.reason == reason, "the original outcome records the gate reason"
        key
      end
      if checker == "model"
        repeated = command("submit", builder, submit_params(first))
        assert_refused("blocked_by_rule", repeated)
        cached_key = @key
      end
      other_builder = Seat.find(second.holder_seat_id)
      other_refusal = command_receipt(other_builder, keys.last).outcome.refusal
      assert_completed owner_command("cancel", { id: first.id })
      assert_completed owner_command("delete_content", { task_id: first.id })

      receipt = command_receipt(builder, keys.first)
      assert receipt.row.refusal["reason"].nil?, "stored command retained deleted content"
      assert receipt.outcome.refusal.reason.nil?, "command read retained deleted content"
      assert_equal [ "blocked_by_rule", rule.id ], [ receipt.outcome.refusal.code, receipt.outcome.refusal.rule_id ]
      assert command_receipt(other_builder, keys.last).outcome.refusal == other_refusal, "another task's outcome changed"
      if cached_key
        cached = command_receipt(builder, cached_key)
        assert cached.outcome.refusal.reason.nil?, "cached decision retained deleted content"
      end
      refute RuleCheck.where(task_id: first.id).where.not(reason: nil).exists?
    end
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
    former_project_builder = saved_claim("claim", own_seat(role: "builder"),
      "task" => { "id" => outside.id, "project_id" => project.id },
      "briefing" => { "brief" => [ { "project_id" => project.id, "text" => "Sample brief" } ] })
    former_project_reviewer = saved_claim("claim_review", own_seat(role: "reviewer"),
      "review" => { "id" => SecureRandom.uuid, "task_id" => outside.id },
      "briefing" => { "brief" => [ { "project_id" => project.id, "text" => "Sample brief" } ] })

    assert_completed owner_command("delete_content", { project_id: project.id })

    assert_equal({ "task" => { "id" => task.id } }, claim.reload.result)
    assert_equal({ "review" => review_identity }, review.reload.result)
    refute old_project_claim.reload.result.key?("input")
    [ former_project_builder, former_project_reviewer ].each do |receipt|
      assert_empty receipt.reload.result.dig("briefing", "brief")
    end
    [ claim, review, old_project_claim ].each do |receipt|
      assert_equal "not_eligible", Leverage::Idempotency.outcome_of(receipt).refusal&.code
    end
  end

  test "deletion appends under the stepped-back clock and keeps replay, event history, and steps intact" do
    task = scenario.task(state: "done", project: scenario.project, details: "Made-up detail")
    before_events = Event.where(workspace_id: scenario.workspace_id).order(:seq).map(&:attributes)
    before_steps = step_snapshot
    assert_empty Leverage::Replay.diff(scenario.workspace_id)

    last_at = before_events.last.fetch("at")
    written = with_clock_behind(last_at) do
      events_written { assert_completed owner_command("delete_content", { task_id: task.id }) }
    end

    assert_equal [ "content.deleted" ], written.map(&:type)
    event = written.first
    assert_operator event.at, :>, last_at
    assert_equal event.at, task.reload.content_deleted_at
    assert_equal before_events, Event.where(workspace_id: scenario.workspace_id, seq: ..before_events.last.fetch("seq"))
      .order(:seq).map(&:attributes)
    assert_equal before_steps, step_snapshot
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
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

  # Like ClockStepBackTest, make the clock read earlier than the last event.
  def with_clock_behind(at)
    lock = Leverage::WorkspaceLock
    original = lock.method(:clock)
    lock.define_singleton_method(:clock) { at - 0.040 }
    yield
  ensure
    lock.define_singleton_method(:clock, original)
  end

  def command_receipt(seat, key)
    Leverage::Reads::CommandOutcome.call(workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id, key: key)
  end

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
      task => %w[title details work_reference], review => %w[handoff_note notes],
      criterion => %w[text], evidence => %w[value], question => %w[text assumption answer], action => %w[description],
      hold => %w[detail], check => %w[reason override_reason], job => %w[input result], pending => %w[params]
    }
  end
end
