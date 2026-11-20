require "test_helper"
require_relative "handoff_support"

# report_signed_out (PRD L684, L694-L698; milestone 3 plan §2.1 rules 4 to
# 7, HE-9, HE-11, HE-12, HD-10; traces 12 and 14): the helper reports that
# a run found its login signed out. The login becomes signed out,
# credential.signed_out is written with it as subject and the seat, and the
# work goes on as after a limit. The sign-out may also leave another task's
# credential_limit hold with nothing to end it: that hold gets the "Account
# signed out" item beside it (HE-11).
class ReportSignedOutTest < ActiveSupport::TestCase
  include HandoffSupport

  setup do
    use_scenario(lease_length_seconds: 3600)
  end

  # Trace 12's accounts: the reviewer's Codex login first, the builder's own
  # Claude login, and a second Claude login that is signed out.
  def trace_12
    @codex_r = scenario.credential(provider: "codex")
    @claude_a = scenario.credential(provider: "claude", model: "claude-model-1")
    @claude_b = scenario.sign_out_credential(scenario.credential(provider: "claude", model: "claude-model-1"))
    @builder = scenario.seat(role: "builder", credential: @claude_a, model: "claude-model-1")
    @task = scenario.task(state: "working", builder: @builder)
  end

  test "trace 12: with no candidate the task is held credential_signed_out naming the login reported, with its item" do
    trace_12
    key = new_key
    written = nil
    ended = runs_ended do
      written = events_written { assert_completed(report_signed_out(@claude_a, @builder, task: @task, key: key)) }
    end

    signed_out, opened, inbox_opened = written
    assert_equal %w[credential.signed_out hold.opened inbox.opened], written.map(&:type)
    assert_equal [ "credential", @claude_a.id, nil, { "seat_id" => @builder.id, "review_id" => nil, "job_id" => nil } ],
      [ signed_out.subject_kind, signed_out.subject_id, signed_out.cause_id, signed_out.payload ]
    assert(written.all? { |event| [ event.actor_kind, event.actor_id, event.command_id, event.task_id ] ==
                                  [ "app", scenario.helper.id, key, @task.id ] })
    hold = open_hold(@task)
    assert_equal [ hold.id, signed_out.id, { "reason" => "credential_signed_out", "rule_id" => nil,
                                             "credential_id" => @claude_a.id } ],
      [ opened.subject_id, opened.cause_id, opened.payload ]
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_equal [ "account_signed_out", @claude_a.id, opened.id ], [ item.kind, item.credential_id, inbox_opened.cause_id ]
    assert_equal "signed_out", @claude_a.reload.state
    assert_nil @claude_a.limited_since
    assert_equal [ [ @builder.id, "signed_out" ] ], ended
  end

  test "with a candidate below available the work switches to it" do
    claude_a = scenario.credential(provider: "claude", model: "claude-model-1")
    codex_h = scenario.credential(provider: "codex")
    builder = scenario.seat(role: "builder", credential: claude_a)
    task = scenario.task(state: "working", builder: builder)

    written = nil
    ensured = runs_ensured { written = events_written { assert_completed(report_signed_out(claude_a, builder, task: task)) } }

    assert_equal %w[credential.signed_out credential.switched], written.map(&:type)
    assert_equal [ codex_h.id, written.first.id ], [ written.last.subject_id, written.last.cause_id ]
    assert_equal codex_h.id, task.reload.credential_id
    assert_equal [ [ builder.id, codex_h.id, [ "Task", task.id ] ] ], ensured
  end

  test "with only a login between the seat's own and the stopped one available the hold opens with no item (HE-4)" do
    claude_o = scenario.credential(provider: "claude")
    claude_m = scenario.credential(provider: "claude")
    codex_s = scenario.credential(provider: "codex")
    builder = scenario.seat(role: "builder", credential: claude_o)
    scenario.limit_credential(claude_o, reset_at: from_now(4000))
    task = scenario.task(state: "working", builder: builder)
    task.update_columns(credential_id: codex_s.id)
    scenario.run(builder, on: codex_s)

    written = events_written { assert_completed(report_signed_out(codex_s, builder, task: task)) }

    assert_equal %w[credential.signed_out hold.opened], written.map(&:type)
    assert_equal [ "credential_signed_out", codex_s.id ], open_hold(task).attributes.values_at("reason", "credential_id")
    assert_empty InboxItem.where(hold_id: open_hold(task).id)
    assert claude_m.reload.state == "active"
  end

  test "a reviewer found signed out with no candidate: review.released, caused by the sign-out (trace 14)" do
    codex_w = scenario.credential(provider: "codex")
    reviewer = scenario.seat(role: "reviewer", credential: codex_w, model: "")
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)

    written = events_written { assert_completed(report_signed_out(codex_w, reviewer, review: review)) }

    signed_out, released = written
    assert_equal %w[credential.signed_out review.released], written.map(&:type)
    assert_equal review.id, signed_out.payload["review_id"]
    assert_equal [ review.id, signed_out.id ], [ released.subject_id, released.cause_id ]
    assert_nil review.reload.reviewer_seat_id
    assert_nil open_hold(task)
  end

  # HE-11: another task held credential_limit, waiting for a reset of the
  # login now found signed out.
  def held_waiting_on(login, other_reset: nil)
    seat = scenario.seat(role: "builder", credential: login)
    task = scenario.task(state: "working", builder: seat)
    scenario.limit_credential(login, reset_at: from_now(6000))
    hold = scenario.hold(task, reason: "credential_limit", credential: login, item: false)
    [ seat, task, hold ]
  end

  test "a sign-out that leaves another task's credential_limit hold with no due time opens Account signed out beside it (HE-11)" do
    grok_z = scenario.credential(provider: "grok")
    codex_w = scenario.limit_credential(scenario.credential(provider: "codex"))
    _, held_task, hold = held_waiting_on(grok_z)
    reviewer = scenario.seat(role: "reviewer", credential: grok_z)
    review_task = scenario.task(state: "in_review")
    review = scenario.review(review_task, reviewer: reviewer)

    written = events_written { assert_completed(report_signed_out(grok_z, reviewer, review: review)) }

    signed_out = written.first
    assert_equal %w[credential.signed_out review.released inbox.opened], written.map(&:type)
    inbox_opened = written.last
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_equal [ "account_signed_out", grok_z.id, { "credential_id" => grok_z.id }, "open" ],
      [ item.kind, item.credential_id, item.facts, item.state ]
    assert_equal [ held_task.id, "inbox_item", item.id, signed_out.id, { "kind" => "account_signed_out" } ],
      [ inbox_opened.task_id, inbox_opened.subject_kind, inbox_opened.subject_id, inbox_opened.cause_id,
        inbox_opened.payload ]
    assert_equal [ "credential_limit", nil ], hold.reload.attributes.values_at("reason", "closed_at"),
      "the hold keeps its reason and stays open"
    assert codex_w.reload.limited?(from_now(0))
  end

  test "a sign-out that leaves the other hold a due time opens nothing beside it (HE-11)" do
    grok_z = scenario.credential(provider: "grok")
    scenario.limit_credential(scenario.credential(provider: "codex"), reset_at: from_now(7000))
    _, _, hold = held_waiting_on(grok_z)
    reviewer = scenario.seat(role: "reviewer", credential: grok_z)
    review_task = scenario.task(state: "in_review")
    review = scenario.review(review_task, reviewer: reviewer)

    written = events_written { assert_completed(report_signed_out(grok_z, reviewer, review: review)) }

    assert_equal %w[credential.signed_out review.released], written.map(&:type)
    assert_empty InboxItem.where(hold_id: hold.id)
  end

  test "a second sign-out report under a new key on a task already held is invalid_state and writes nothing (review)" do
    trace_12
    assert_completed(report_signed_out(@claude_a, @builder, task: @task))
    holds = Hold.where(task_id: @task.id).count
    items = InboxItem.where(about_id: @task.id, state: "open").count

    written = events_written { assert_refused("invalid_state", report_signed_out(@claude_a, @builder, task: @task)) }

    assert_empty written
    assert_equal [ holds, items ], [ Hold.where(task_id: @task.id).count, InboxItem.where(about_id: @task.id, state: "open").count ]
    assert_equal 1, Event.where(task_id: @task.id, type: "credential.signed_out").count
  end

  test "the refusals of HE-9 apply: a job is 404, another seat is not_holder, a Finishing task invalid_state" do
    trace_12
    other = scenario.seat(role: "builder", credential: @claude_a)
    assert_raises(T::NotFound) { report_signed_out(@claude_a, @builder, task: @task, job_id: SecureRandom.uuid) }
    assert_refused("not_holder", report_signed_out(@claude_a, other, task: @task))
    finisher = scenario.seat(role: "builder", credential: @claude_a)
    assert_refused("invalid_state", report_signed_out(@claude_a, finisher, task: scenario.finishing_task(builder: finisher)))
    assert_equal "active", @claude_a.reload.state
    assert_empty Event.where(workspace_id: scenario.workspace_id, type: "credential.signed_out", subject_id: @claude_a.id)
  end
end
