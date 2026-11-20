require "test_helper"
require_relative "handoff_support"

# report_limit (PRD L650-L703; milestone 3 plan §2.1 rules 4 to 6, HE-4,
# HE-8, HE-9, HE-12, HE-13, HE-22, HE-32, HE-33, HD-10; traces 11, 13 and
# 14): the helper reports that a run met a provider limit. The credential is
# marked, credential.limit_reached is written with it as subject, the
# seat's run is recorded as ended, and the work goes on: on the next
# candidate (credential.switched and a start on it), or, with none, the task
# is held (credential_limit or credential_signed_out, an item only when the
# owner must act) or the review released.
class ReportLimitTest < ActiveSupport::TestCase
  include HandoffSupport

  setup do
    use_scenario(lease_length_seconds: 3600)
  end

  # Trace 11's accounts: a reviewer's Grok login first, then the builder's
  # own Claude login, then a Codex login with no model (HE-5).
  def trace_11
    @grok_r = scenario.credential(provider: "grok", model: "grok-model-1")
    @claude_a = scenario.credential(provider: "claude", model: "claude-model-1")
    @codex_h = scenario.credential(provider: "codex", model: nil)
    @builder = scenario.seat(role: "builder", credential: @claude_a, model: "claude-model-1", effort: "high")
    @task = scenario.task(state: "working", builder: @builder)
  end

  test "trace 11: a limit with a candidate below switches the work to it, and a second limit holds the task" do
    trace_11
    reset = from_now(1800)
    key = new_key
    written = nil
    ensured = nil
    ended = runs_ended do
      ensured = runs_ensured do
        written = events_written { assert_completed(report_limit(@claude_a, @builder, task: @task, reset_at: reset, key: key)) }
      end
    end

    limit, switched = written
    assert_equal %w[credential.limit_reached credential.switched], written.map(&:type)
    assert_equal [ "credential", @claude_a.id, nil ], [ limit.subject_kind, limit.subject_id, limit.cause_id ]
    assert_equal [ "credential", @codex_h.id, limit.id ], [ switched.subject_kind, switched.subject_id, switched.cause_id ]
    written.each do |event|
      assert_equal [ "app", scenario.helper.id, @task.id, 0, key ],
        [ event.actor_kind, event.actor_id, event.task_id, event.round, event.command_id ]
    end
    assert_equal({ "seat_id" => @builder.id, "review_id" => nil, "job_id" => nil, "window" => "five_hour" },
      limit.payload.except("reset_at"))
    assert_in_delta reset.to_f, Time.iso8601(limit.payload["reset_at"]).to_f, 0.000_001
    assert_equal({ "from_credential_id" => @claude_a.id, "model" => nil, "seat_id" => @builder.id, "review_id" => nil,
                   "job_id" => nil }, switched.payload)

    @claude_a.reload
    assert_in_delta limit.at.to_f, @claude_a.limited_since.to_f, 0.000_001
    assert_in_delta reset.to_f, @claude_a.limited_until.to_f, 0.000_001
    assert_equal "active", @claude_a.state
    assert_equal [ "working", @builder.id, @codex_h.id ], @task.reload.attributes.values_at("state", "holder_seat_id", "credential_id")
    assert_equal [ [ @builder.id, @codex_h.id, [ "Task", @task.id ] ] ], ensured
    assert_equal [ [ @builder.id, "limit" ] ], ended
    assert_nil open_hold(@task)

    lease = @task.lease_due_at
    second = events_written { assert_completed(report_limit(@codex_h, @builder, task: @task, reset_at: from_now(2400))) }
    limit2, opened = second
    assert_equal %w[credential.limit_reached hold.opened], second.map(&:type)
    hold = open_hold(@task)
    assert_equal [ "hold", hold.id, limit2.id, "app", scenario.helper.id ],
      [ opened.subject_kind, opened.subject_id, opened.cause_id, opened.actor_kind, opened.actor_id ]
    assert_equal({ "reason" => "credential_limit", "rule_id" => nil, "credential_id" => @claude_a.id }, opened.payload,
      "HE-13: the candidate that resets first")
    assert_equal [ "credential_limit", @claude_a.id ], [ hold.reason, hold.credential_id ]
    assert_empty InboxItem.where(hold_id: hold.id), "a reset time is known: no item (L697)"
    assert_equal [ "working", @codex_h.id, lease ], @task.reload.attributes.values_at("state", "credential_id", "lease_due_at"),
      "credential_limit lets the lease run"
  end

  test "the result is completed with no result (HE-8)" do
    trace_11
    outcome = assert_completed(report_limit(@claude_a, @builder, task: @task, reset_at: from_now(600)))
    assert_nil outcome.result
  end

  test "with no reset time anywhere the hold names the stopped login and opens Limit with no reset time (HE-13)" do
    grok_z = scenario.credential(provider: "grok", model: "grok-model-1")
    codex_w = scenario.limit_credential(scenario.credential(provider: "codex"))
    builder = scenario.seat(role: "builder", credential: grok_z)
    task = scenario.task(state: "working", builder: builder)

    written = events_written { assert_completed(report_limit(grok_z, builder, task: task, window: "weekly")) }

    limit, opened, inbox_opened = written
    assert_equal %w[credential.limit_reached hold.opened inbox.opened], written.map(&:type)
    assert_equal({ "seat_id" => builder.id, "review_id" => nil, "job_id" => nil, "window" => "weekly", "reset_at" => nil },
      limit.payload)
    assert_equal grok_z.id, opened.payload["credential_id"]
    item = InboxItem.find_by!(hold_id: open_hold(task).id)
    assert_equal [ "limit_with_no_reset_time", grok_z.id, { "credential_id" => grok_z.id }, [] ],
      [ item.kind, item.credential_id, item.facts, item.choices ]
    assert_equal [ "inbox_item", item.id, opened.id, { "kind" => "limit_with_no_reset_time" } ],
      [ inbox_opened.subject_kind, inbox_opened.subject_id, inbox_opened.cause_id, inbox_opened.payload ]
    grok_z.reload
    assert grok_z.limited_since
    assert_nil grok_z.limited_until
    assert codex_w.reload.limited?(from_now(86_400))
  end

  test "a limit on a lower login after the seat's own has reset goes back to the seat's own at once (HE-4)" do
    claude_m = scenario.credential(provider: "claude", model: "claude-model-1")
    codex_s = scenario.credential(provider: "codex")
    builder = scenario.seat(role: "builder", credential: claude_m, model: "claude-model-1")
    scenario.limit_credential(claude_m, since: from_now(-900), reset_at: from_now(-1))
    task = scenario.task(state: "working", builder: builder)
    task.update_columns(credential_id: codex_s.id)
    scenario.run(builder, on: codex_s)

    written = nil
    ensured = runs_ensured do
      written = events_written { assert_completed(report_limit(codex_s, builder, task: task, reset_at: from_now(3000))) }
    end

    assert_equal %w[credential.limit_reached credential.switched], written.map(&:type)
    switched = written.last
    assert_equal [ claude_m.id, { "from_credential_id" => codex_s.id, "model" => "claude-model-1", "seat_id" => builder.id,
                                  "review_id" => nil, "job_id" => nil } ], [ switched.subject_id, switched.payload ]
    assert_equal claude_m.id, task.reload.credential_id
    assert_equal [ [ builder.id, claude_m.id, [ "Task", task.id ] ] ], ensured
  end

  test "with only a login between the seat's own and the stopped one available, the hold opens with no item and is due at once (HE-4)" do
    claude_o = scenario.credential(provider: "claude", model: "claude-model-1")
    claude_m = scenario.credential(provider: "claude", model: "claude-model-1")
    codex_s = scenario.credential(provider: "codex")
    builder = scenario.seat(role: "builder", credential: claude_o)
    scenario.limit_credential(claude_o, reset_at: from_now(4000))
    scenario.limit_credential(claude_m, since: from_now(-900), reset_at: from_now(-1))
    task = scenario.task(state: "working", builder: builder)
    task.update_columns(credential_id: codex_s.id)
    scenario.run(builder, on: codex_s)

    written = events_written { assert_completed(report_limit(codex_s, builder, task: task, reset_at: from_now(5000))) }

    assert_equal %w[credential.limit_reached hold.opened], written.map(&:type)
    hold = open_hold(task)
    assert_equal [ "credential_limit", claude_o.id ], [ hold.reason, hold.credential_id ], "the login that resets first"
    assert_empty InboxItem.where(hold_id: hold.id)
    assert_equal codex_s.id, task.reload.credential_id, "rule 4 does not take the login between them at the report"
    due = Leverage::Candidates.due_at(builder, task, from_now(0))
    assert_in_delta written.last.effective_at.to_f, due.to_f, 0.000_001, "rule 8: at once"
  end

  test "with a candidate signed out the hold is credential_signed_out naming it, with Account signed out (trace 13, HE-12)" do
    scenario.credential(provider: "grok", model: "grok-model-1")
    claude_a = scenario.credential(provider: "claude", model: "claude-model-1")
    codex_b = scenario.sign_out_credential(scenario.credential(provider: "codex"))
    builder = scenario.seat(role: "builder", credential: claude_a)
    task = scenario.task(state: "working", builder: builder)

    written = events_written { assert_completed(report_limit(claude_a, builder, task: task, reset_at: from_now(3600))) }

    assert_equal %w[credential.limit_reached hold.opened inbox.opened], written.map(&:type)
    hold = open_hold(task)
    assert_equal [ "credential_signed_out", codex_b.id ], [ hold.reason, hold.credential_id ]
    assert_equal({ "reason" => "credential_signed_out", "rule_id" => nil, "credential_id" => codex_b.id }, written[1].payload)
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_equal [ "account_signed_out", codex_b.id, { "credential_id" => codex_b.id }, [ "sign_in_again" ] ],
      [ item.kind, item.credential_id, item.facts, item.choices ]
    task.reload
    assert_nil task.lease_due_at, "credential_signed_out pauses the lease"
    assert task.lease_time_left_while_paused
  end

  test "a new limit keeps the later of two reset times, and a reset time not after observed_at is none (HE-22, HE-32)" do
    shared = scenario.credential(provider: "claude")
    builder = scenario.seat(role: "builder", credential: shared)
    other = scenario.seat(role: "builder", credential: shared)
    later = from_now(3000)
    scenario.limit_credential(shared, reset_at: later)
    task = scenario.task(state: "working", builder: builder)
    second = scenario.task(state: "working", builder: other)

    written = events_written { assert_completed(report_limit(shared, builder, task: task, reset_at: from_now(1000))) }
    shared.reload
    assert_in_delta later.to_f, shared.limited_until.to_f, 0.000_001
    assert_in_delta written.first.at.to_f, shared.limited_since.to_f, 0.000_001

    observed = from_now(0)
    assert_completed(report_limit(shared, other, task: second, reset_at: observed - 5, observed_at: observed))
    assert_nil shared.reload.limited_until, "a reset time that is not after observed_at is stored as none"
    assert_nil Event.where(task_id: second.id, type: "credential.limit_reached").sole.payload["reset_at"]
  end

  # Review: a reset time further off than the window it names can last is
  # not one the provider gave; it is stored as none, which the next
  # Verify clears (HE-2), so no one forged time parks a login for good.
  test "a reset time further off than its window can last is stored as none (review)" do
    observed = from_now(0)
    {
      "five_hour" => [ 5.hours, 30.days ], "weekly" => [ 7.days, 60.days ], "per_model" => [ 7.days, 60.days ],
      "spend" => [ 31.days, 400.days ], nil => [ 31.days, 400.days ]
    }.each do |window, (inside, beyond)|
      shared = scenario.credential(provider: "claude")
      seat = scenario.seat(role: "builder", credential: shared)
      far = scenario.task(state: "working", builder: seat)
      assert_completed(report_limit(shared, seat, task: far, window: window, reset_at: observed + beyond, observed_at: observed))
      assert_nil shared.reload.limited_until, "#{window.inspect}: #{beyond.inspect} is beyond the window"
      assert shared.limited_since
      assert_nil Event.where(task_id: far.id, type: "credential.limit_reached").sole.payload["reset_at"]

      kept = scenario.credential(provider: "claude")
      other = scenario.seat(role: "builder", credential: kept)
      near = scenario.task(state: "working", builder: other)
      assert_completed(report_limit(kept, other, task: near, window: window, reset_at: observed + inside, observed_at: observed))
      assert_in_delta (observed + inside).to_f, kept.reload.limited_until.to_f, 0.000_001, "#{window.inspect}: within"
    end
  end

  test "a reviewer's limit with a candidate below switches the review, with its model (trace 14, HE-5, HE-41)" do
    gemini = scenario.credential(provider: "gemini")
    grok_x = scenario.credential(provider: "grok", model: "grok-model-1")
    reviewer = scenario.seat(role: "reviewer", credential: gemini, model: "gemini-model-1")
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)

    written = nil
    ensured = runs_ensured do
      written = events_written { assert_completed(report_limit(gemini, reviewer, review: review, reset_at: from_now(900))) }
    end

    limit, switched = written
    assert_equal %w[credential.limit_reached credential.switched], written.map(&:type)
    assert_equal [ task.id, review.id ], [ limit.task_id, limit.payload["review_id"] ]
    assert_equal({ "from_credential_id" => gemini.id, "model" => "grok-model-1", "seat_id" => reviewer.id,
                   "review_id" => review.id, "job_id" => nil }, switched.payload)
    assert_equal [ reviewer.id, grok_x.id ], review.reload.attributes.values_at("reviewer_seat_id", "credential_id")
    assert_equal [ [ reviewer.id, grok_x.id, [ "Review", review.id ] ] ], ensured
  end

  test "a reviewer's limit with no candidate releases the review, caused by the limit, and opens no hold" do
    gemini = scenario.credential(provider: "gemini")
    reviewer = scenario.seat(role: "reviewer", credential: gemini)
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)

    written = events_written { assert_completed(report_limit(gemini, reviewer, review: review, reset_at: from_now(900))) }

    limit, released = written
    assert_equal %w[credential.limit_reached review.released], written.map(&:type)
    assert_equal [ "review", review.id, limit.id, "app", scenario.helper.id ],
      [ released.subject_kind, released.subject_id, released.cause_id, released.actor_kind, released.actor_id ]
    assert_equal [ nil, nil ], review.reload.attributes.values_at("reviewer_seat_id", "lease_due_at")
    assert_equal "in_review", task.reload.state
    assert_nil open_hold(task)
  end

  # HE-9: the refusals, in order. A refused report marks no credential
  # and writes no credential event.

  test "a report that names a job is 404, whatever else it names (HE-33)" do
    trace_11
    assert_raises(T::NotFound) { report_limit(@claude_a, @builder, job_id: SecureRandom.uuid) }
    assert_raises(T::NotFound) { report_limit(@claude_a, @builder, task: @task, job_id: SecureRandom.uuid) }
    assert_nil @claude_a.reload.limited_since
  end

  test "a credential, seat, task or review that is not in the workspace is 404" do
    trace_11
    other = Scenario.new
    foreign = other.credential
    assert_raises(T::NotFound) { report_limit(foreign, @builder, task: @task) }
    assert_raises(T::NotFound) do
      helper_command("report_limit", limit_params(@claude_a, @builder, task: @task).merge("seat_id" => SecureRandom.uuid))
    end
    assert_raises(T::NotFound) do
      helper_command("report_limit", limit_params(@claude_a, @builder, task: @task).merge("task_id" => SecureRandom.uuid))
    end
    assert_raises(T::NotFound) do
      helper_command("report_limit", limit_params(@claude_a, @builder).merge("review_id" => SecureRandom.uuid))
    end
    assert_raises(T::NotFound) { report_limit(@claude_a, @builder, task: other.task(state: "backlog")) }
    assert_nil @claude_a.reload.limited_since
  end

  test "a credential that is not an added login, a seat with no credential, and not exactly one id are 422 invalid" do
    trace_11
    token = scenario.credential(kind: "api_token", provider: "claude")
    adding = scenario.credential(provider: "codex", added: false)
    own = scenario.seat(role: "builder", provider: "codex")
    own_task = scenario.task(state: "working", builder: own)
    review = Review.create!(workspace_id: scenario.workspace_id, task_id: @task.id, round: 0)

    assert_raises(T::Invalid) { report_limit(token, @builder, task: @task) }
    assert_raises(T::Invalid) { report_limit(adding, @builder, task: @task) }
    assert_raises(T::Invalid) { report_limit(@claude_a, own, task: own_task) }
    assert_raises(T::Invalid) { report_limit(@claude_a, @builder) }
    assert_raises(T::Invalid) { report_limit(@claude_a, @builder, task: @task, review: review) }
    assert_raises(T::Invalid) do
      helper_command("report_limit", limit_params(@claude_a, @builder, task: @task).merge("credential_id" => @codex_h.id))
    end
    assert_nil @claude_a.reload.limited_since
  end

  test "lease_expired, task_cancelled, not_holder and invalid_state come in that order, and mark nothing" do
    trace_11
    other = scenario.seat(role: "builder", credential: @claude_a)

    assert_refused("not_holder", report_limit(@claude_a, other, task: @task))

    finisher = scenario.seat(role: "builder", credential: @claude_a)
    finishing = scenario.finishing_task(builder: finisher)
    assert_refused("invalid_state", report_limit(@claude_a, finisher, task: finishing))
    # not_holder ranks before invalid_state.
    assert_refused("not_holder", report_limit(@claude_a, other, task: finishing))

    # The credential reported is not the one recorded for the work.
    assert_refused("invalid_state", report_limit(@codex_h, @builder, task: @task))

    canceller = scenario.seat(role: "builder", credential: @claude_a)
    cancelled = scenario.task(state: "working", builder: canceller)
    cancelled.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    scenario.append("task.cancelled", task: cancelled, actor_kind: "owner", actor_id: scenario.owner.id)
    assert_refused("task_cancelled", report_limit(@claude_a, canceller, task: cancelled))

    scenario.make_due(@task)
    written = events_written { assert_refused("lease_expired", report_limit(@claude_a, @builder, task: @task)) }
    assert_equal %w[task.lease_expired], written.map(&:type), "only the timer due on the task, applied first"

    assert_nil @claude_a.reload.limited_since
    assert_empty Event.where(workspace_id: scenario.workspace_id, type: "credential.limit_reached")
  end

  test "a reviewer's report on a review it does not hold is not_holder" do
    gemini = scenario.credential(provider: "gemini")
    reviewer = scenario.seat(role: "reviewer", credential: gemini)
    task = scenario.task(state: "in_review")
    review = Review.find_by!(task_id: task.id)

    assert_refused("not_holder", report_limit(gemini, reviewer, review: review))
    assert_nil gemini.reload.limited_since
  end

  test "a second limit report under a new key on a task already held is invalid_state and writes nothing (review)" do
    grok_z = scenario.credential(provider: "grok", model: "grok-model-1")
    builder = scenario.seat(role: "builder", credential: grok_z)
    task = scenario.task(state: "working", builder: builder)
    assert_completed(report_limit(grok_z, builder, task: task, window: "weekly"))
    holds = Hold.where(task_id: task.id).count
    items = InboxItem.where(about_id: task.id).count

    written = events_written { assert_refused("invalid_state", report_limit(grok_z, builder, task: task, window: "weekly")) }

    assert_empty written
    assert_equal [ holds, items ], [ Hold.where(task_id: task.id).count, InboxItem.where(about_id: task.id).count ]
    assert_equal 1, Event.where(task_id: task.id, type: "credential.limit_reached").count
  end

  # Review: a candidate that rule 3 passes over for the task is not one
  # the hold may wait for (PRD L670): a signed-out login the task's
  # minimum strength rank passes over neither makes the hold
  # credential_signed_out nor gets its item.
  test "a signed-out login the task passes over leaves the hold credential_limit, with Limit with no reset time (review)" do
    claude = scenario.credential(provider: "claude", model: "claude-model-1", strength_rank: 3)
    codex = scenario.sign_out_credential(scenario.credential(provider: "codex", strength_rank: 1))
    builder = scenario.seat(role: "builder", credential: claude, strength_rank: 3)
    task = scenario.task(state: "working", builder: builder)
    task.update_columns(minimum_strength_rank: 3)

    written = events_written { assert_completed(report_limit(claude, builder, task: task, window: "weekly")) }

    assert_equal %w[credential.limit_reached hold.opened inbox.opened], written.map(&:type)
    hold = open_hold(task)
    assert_equal [ "credential_limit", claude.id ], [ hold.reason, hold.credential_id ]
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_equal [ "limit_with_no_reset_time", claude.id ], [ item.kind, item.credential_id ]
    refute_equal codex.id, item.credential_id
  end

  test "the same report sent again with the same key writes nothing more" do
    trace_11
    key = new_key
    params = limit_params(@claude_a, @builder, task: @task, reset_at: from_now(900))
    assert_completed(helper_command("report_limit", params, key: key))
    limited = @claude_a.reload.limited_since
    again = nil
    written = events_written { again = helper_command("report_limit", params, key: key) }

    assert_empty written
    assert_completed(again)
    assert_equal limited, @claude_a.reload.limited_since
  end
end
