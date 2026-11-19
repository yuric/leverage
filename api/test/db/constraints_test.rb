require "test_helper"
require_relative "rows"

# The constraints the database enforces, proven by inserting rows (PRD, Data
# model, "Constraints the database enforces"; plan C2-C19, DB-8, DB-33).
class ConstraintsTest < ActiveSupport::TestCase
  include DbRows

  test "C2: two events of one workspace cannot share a seq" do
    event(seq: 41)
    assert_rejected(ActiveRecord::RecordNotUnique) { event(seq: 41) }
    other = insert("workspaces", {})
    assert_accepted { event(workspace_id: other, seq: 41) }
  end

  test "C3: command_id is indexed and several events share one" do
    task_id = task
    assert_accepted do
      event(task_id: task_id, type: "task.claimed", command_id: "made-up-key")
      event(task_id: task_id, type: "check.queued", command_id: "made-up-key")
    end
    indexed = sql("SELECT count(*) FROM pg_indexes WHERE tablename = 'events' AND indexdef LIKE '%(command_id)'")
    assert_equal 1, indexed.rows.first.first
  end

  test "DB-8: an event's round is null exactly when it has no task, and its subject is a pair" do
    task_id = task
    assert_rejected { event(task_id: task_id, round: nil) }
    assert_rejected { event(task_id: nil, round: 0) }
    assert_rejected { event(subject_kind: "seat", subject_id: nil) }
    assert_rejected { event(subject_kind: nil, subject_id: SecureRandom.uuid) }
    assert_accepted { event(type: "seat.connected", subject_kind: "seat", subject_id: seat) }
  end

  test "C4: a command key is unique per caller, and another caller may reuse it" do
    caller_id = SecureRandom.uuid
    command = ->(kind, id) {
      insert("commands", workspace_id: workspace, caller_kind: kind, caller_id: id, key: "made-up-key",
        command: "claim", request_hash: "made-up", outcome: "completed")
    }
    command.call("seat", caller_id)
    assert_rejected(ActiveRecord::RecordNotUnique) { command.call("seat", caller_id) }
    assert_accepted { command.call("seat", SecureRandom.uuid) }
    assert_accepted { command.call("owner", caller_id) }
  end

  def step(task_id, opened_at: Time.current, closed_at: nil)
    insert("task_steps", workspace_id: workspace, task_id: task_id, round: 0, kind: "build",
      step_class: "working", opened_at: opened_at, closed_at: closed_at, opening_event_id: event(task_id: task_id))
  end

  test "C5: a task has at most one open step" do
    task_id = task
    step(task_id, opened_at: 2.minutes.ago, closed_at: 1.minute.ago)
    step(task_id)
    assert_rejected(ActiveRecord::RecordNotUnique) { step(task_id) }
    assert_accepted { step(task) }
  end

  test "C16: no step closes before it opens" do
    assert_rejected { step(task, opened_at: Time.current, closed_at: 1.second.ago) }
    assert_accepted { step(task, opened_at: 1.second.ago, closed_at: 1.second.ago) }
  end

  def check(task_id:, subject_id: nil, round: 0, input_hash: "made-up-hash")
    insert("rule_checks", workspace_id: workspace, task_id: task_id, rule_id: rule, rule_version_id: rule_version,
      hook: "task.before_ready", round: round, subject_kind: subject_id && "seat", subject_id: subject_id,
      input_hash: input_hash)
  end

  test "C6: a check is unique on its key, null subject and null task included" do
    task_id = task
    seat_id = seat
    check(task_id: task_id, subject_id: seat_id)
    assert_rejected(ActiveRecord::RecordNotUnique) { check(task_id: task_id, subject_id: seat_id) }
    check(task_id: task_id)
    assert_rejected(ActiveRecord::RecordNotUnique) { check(task_id: task_id) }
    check(task_id: nil, round: nil)
    assert_rejected(ActiveRecord::RecordNotUnique) { check(task_id: nil, round: nil) }
    assert_accepted { check(task_id: task_id, input_hash: "another-made-up-hash") }
  end

  def pending_transition(task_id, state: "pending")
    insert("pending_transitions", workspace_id: workspace, task_id: task_id, command_key: SecureRandom.uuid,
      command: "claim", requester_kind: "seat", requester_id: SecureRandom.uuid, state: state)
  end

  test "C17: a task has at most one pending transition; a cancelled one does not count" do
    task_id = task
    pending_transition(task_id, state: "cancelled")
    pending_transition(task_id)
    assert_rejected(ActiveRecord::RecordNotUnique) { pending_transition(task_id) }
    assert_accepted { pending_transition(task_id, state: "completed") }
  end

  test "C18: a seat holds at most one task and reviews at most one review" do
    seat_id = seat
    task(holder_seat_id: seat_id, state: "working")
    assert_rejected(ActiveRecord::RecordNotUnique) { task(holder_seat_id: seat_id, state: "working") }
    assert_accepted { task(holder_seat_id: nil, state: "ready") }

    review = ->(task_id) { insert("reviews", workspace_id: workspace, task_id: task_id, round: 0, reviewer_seat_id: seat_id) }
    review.call(task(state: "in_review"))
    assert_rejected(ActiveRecord::RecordNotUnique) { review.call(task(state: "in_review")) }
    assert_accepted { insert("reviews", workspace_id: workspace, task_id: task(state: "in_review"), round: 0) }
  end

  test "one review row per task and round" do
    task_id = task(state: "in_review")
    insert("reviews", workspace_id: workspace, task_id: task_id, round: 0)
    assert_rejected(ActiveRecord::RecordNotUnique) { insert("reviews", workspace_id: workspace, task_id: task_id, round: 0) }
    assert_accepted { insert("reviews", workspace_id: workspace, task_id: task_id, round: 1) }
  end

  test "C19: a credential name is unique within its provider and kind" do
    credential(name: "work")
    assert_rejected(ActiveRecord::RecordNotUnique) { credential(name: "work") }
    assert_accepted { credential(name: "work", provider: "codex") }
    assert_accepted { credential(name: "work", kind: "api_token", provider: "claude_api") }
  end

  test "at most one Gemini login per workspace; Gemini API tokens are not limited" do
    credential(provider: "gemini")
    assert_rejected(ActiveRecord::RecordNotUnique) { credential(provider: "gemini") }
    assert_accepted do
      credential(provider: "gemini_api", kind: "api_token")
      credential(provider: "gemini_api", kind: "api_token")
    end
  end

  test "credential positions are unique per workspace and two can swap in one transaction" do
    first = credential(position: 1)
    second = credential(position: 2)
    assert_accepted do
      sql("UPDATE credentials SET position = 2 WHERE id = $1", first)
      sql("UPDATE credentials SET position = 1 WHERE id = $1", second)
      db.execute("SET CONSTRAINTS ALL IMMEDIATE")
    end
    assert_rejected(ActiveRecord::RecordNotUnique) do
      credential(position: 1)
      db.execute("SET CONSTRAINTS ALL IMMEDIATE")
    end
  end

  test "criterion positions are unique per task among criteria not removed" do
    task_id = task
    criterion = ->(**values) {
      insert("criteria", { workspace_id: workspace, task_id: task_id, position: 1, kind: "build" }.merge(values))
    }
    criterion.call(removed_at: Time.current)
    criterion.call
    assert_rejected(ActiveRecord::RecordNotUnique) { criterion.call }
  end

  test "action positions are unique per task" do
    task_id = task
    action = -> { insert("actions", workspace_id: workspace, task_id: task_id, position: 1, kind: "publish") }
    action.call
    assert_rejected(ActiveRecord::RecordNotUnique) { action.call }
  end

  def inbox_item(kind:, about_kind: "task", about_id: nil, hold_id: nil, state: "open")
    insert("inbox_items", workspace_id: workspace, kind: kind, about_kind: about_kind, about_id: about_id,
      hold_id: hold_id, choices: [], facts: {}, state: state, opened_at: Time.current)
  end

  test "DB-33: one open orchestrator-offline item per workspace" do
    inbox_item(kind: "orchestrator_offline", about_kind: "workspace", state: "resolved")
    inbox_item(kind: "orchestrator_offline", about_kind: "workspace")
    assert_rejected(ActiveRecord::RecordNotUnique) { inbox_item(kind: "orchestrator_offline", about_kind: "workspace") }
  end

  test "DB-33: one open no-reviewer-eligible item per task" do
    task_id = task
    inbox_item(kind: "no_reviewer_eligible", about_id: task_id)
    assert_rejected(ActiveRecord::RecordNotUnique) { inbox_item(kind: "no_reviewer_eligible", about_id: task_id) }
    assert_accepted { inbox_item(kind: "no_reviewer_eligible", about_id: task) }
  end

  test "DB-33: one open item per hold" do
    task_id = task
    hold = insert("holds", workspace_id: workspace, task_id: task_id, reason: "access", opened_at: Time.current,
      opened_by_kind: "seat")
    inbox_item(kind: "access_request", about_id: task_id, hold_id: hold)
    assert_rejected(ActiveRecord::RecordNotUnique) { inbox_item(kind: "access_request", about_id: task_id, hold_id: hold) }
  end

  test "a briefing is acknowledged once per seat, lease and hash" do
    task_id = task
    seat_id = seat
    lease = event(task_id: task_id, type: "task.claimed")
    acknowledge = ->(hash) {
      insert("briefing_acknowledgements", workspace_id: workspace, seat_id: seat_id, task_id: task_id,
        lease_event_id: lease, briefing_hash: hash, acknowledged_at: Time.current)
    }
    acknowledge.call("made-up-hash")
    assert_rejected(ActiveRecord::RecordNotUnique) { acknowledge.call("made-up-hash") }
    assert_accepted { acknowledge.call("another-made-up-hash") }
  end

  test "a reading is deleted with its credential; a seat's credential cannot be deleted" do
    used = credential
    seat(credential_id: used)
    assert_rejected(ActiveRecord::InvalidForeignKey) { sql("DELETE FROM credentials WHERE id = $1", used) }

    read = credential
    insert("credential_readings", workspace_id: workspace, credential_id: read, observed_at: Time.current, state: "ok")
    assert_accepted { sql("DELETE FROM credentials WHERE id = $1", read) }
    assert_equal 0, sql("SELECT count(*) FROM credential_readings WHERE credential_id = $1", read).rows.first.first
  end
end
