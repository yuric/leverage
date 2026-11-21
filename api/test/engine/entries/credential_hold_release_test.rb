require "test_helper"
require_relative "handoff_support"

# The credential_hold_release timer (PRD L696-L699; timers.json; milestone
# 3 plan §2.1 rules 7 and 8, HE-21, HE-23; traces 11 and 14): a task's
# credential hold closes at its due time, the task's last effective time
# when one of the holder's candidates is available, else the earliest reset
# among its signed-in candidates. The work goes on on the first available
# candidate: hold.closed, credential.switched when that is not the
# credential recorded for the task, inbox.resolved for an open item, and a
# start on it. The app writes them, with no command_id, at the due time.
class CredentialHoldReleaseTest < ActiveSupport::TestCase
  include HandoffSupport

  setup do
    use_scenario(lease_length_seconds: 3600)
    @claude_a = scenario.credential(provider: "claude", model: "claude-model-1")
    @codex_h = scenario.credential(provider: "codex")
    @builder = scenario.seat(role: "builder", credential: @claude_a, model: "claude-model-1")
    @task = scenario.task(state: "working", builder: @builder)
    @task.update_columns(credential_id: @codex_h.id)
    scenario.run(@builder, on: @codex_h)
    scenario.limit_credential(@codex_h, reset_at: from_now(3000))
  end

  def last_effective_at(task = @task) = Event.where(task_id: task.id).maximum(:effective_at)

  # Trace 11's hold: the seat's own login resets first, a moment after the
  # task's last event, so the due time is the reset and not the last event.
  def held_until_own_resets
    scenario.limit_credential(@claude_a, reset_at: from_now(3600))
    hold = scenario.hold(@task, reason: "credential_limit", credential: @claude_a, item: false)
    reset = last_effective_at + 0.002
    @claude_a.update_columns(limited_until: reset)
    [ hold, reset ]
  end

  test "trace 11: at the earliest reset the hold closes and the work goes back to the seat's own login" do
    hold, reset = held_until_own_resets
    outcome = nil
    written = nil
    ensured = runs_ensured { written = events_written { outcome = assert_completed(release_timer) } }

    closed, switched = written
    assert_equal %w[hold.closed credential.switched], written.map(&:type)
    assert_equal [ "hold", hold.id, nil ], [ closed.subject_kind, closed.subject_id, closed.cause_id ]
    assert_equal({ "reason" => "credential_limit", "rule_id" => nil, "credential_id" => @claude_a.id, "lease_seat_id" => nil,
                   "wait_cause" => nil }, closed.payload)
    assert_equal [ @claude_a.id, closed.id ], [ switched.subject_id, switched.cause_id ]
    assert_equal({ "from_credential_id" => @codex_h.id, "model" => "claude-model-1", "seat_id" => @builder.id,
                   "review_id" => nil, "job_id" => nil }, switched.payload)
    written.each do |event|
      assert_equal [ "app", nil, nil, @task.id ], [ event.actor_kind, event.actor_id, event.command_id, event.task_id ]
      assert_in_delta reset.to_f, event.effective_at.to_f, 0.000_001, "the due time (HE-23)"
    end
    assert hold.reload.closed_at
    assert_equal @claude_a.id, @task.reload.credential_id
    assert_equal [ [ @builder.id, @claude_a.id, [ "Task", @task.id ] ] ], ensured
    assert_equal({ "released_task_ids" => [ @task.id ] }, outcome.result)
  end

  test "a hold whose due time has not come stays open" do
    scenario.limit_credential(@claude_a, reset_at: from_now(3600))
    hold = scenario.hold(@task, reason: "credential_limit", credential: @claude_a, item: false)

    written = events_written do
      assert_completed(release_timer)
      assert_equal({ "released_task_ids" => [] }, assert_completed(release_timer("task_id" => @task.id)).result)
    end

    assert_empty written
    assert_nil hold.reload.closed_at
  end

  test "trace 14: with a login between them available the hold is due at once, at the task's last effective time" do
    @codex_h.update_columns(position: 10)
    claude_m = scenario.credential(provider: "claude", model: "claude-model-1")
    scenario.limit_credential(@claude_a, reset_at: from_now(3600))
    hold = scenario.hold(@task, reason: "credential_limit", credential: @claude_a, item: false)
    last = last_effective_at

    written = events_written { assert_completed(release_timer) }

    assert_equal %w[hold.closed credential.switched], written.map(&:type)
    assert_equal claude_m.id, written.last.subject_id
    assert(written.all? { |event| (event.effective_at - last).abs < 0.000_001 })
    assert hold.reload.closed_at
  end

  test "a credential_signed_out hold closes at another candidate's reset, and its item resolves with no choice" do
    codex_b = scenario.sign_out_credential(scenario.credential(provider: "codex"))
    scenario.limit_credential(@claude_a, reset_at: from_now(3600))
    hold = scenario.hold(@task, reason: "credential_signed_out", credential: codex_b,
      facts: { credential_id: codex_b.id })
    item = InboxItem.find_by!(hold_id: hold.id)
    @claude_a.update_columns(limited_until: last_effective_at + 0.002)

    written = events_written { assert_completed(release_timer) }

    assert_equal %w[hold.closed credential.switched inbox.resolved], written.map(&:type)
    assert_equal [ item.id, nil, { "choice" => nil } ], written.last.attributes.values_at("subject_id", "cause_id", "payload")
    assert_equal "resolved", item.reload.state
    @task.reload
    assert @task.lease_due_at, "the lease clock runs again"
    assert_nil @task.lease_time_left_while_paused
  end

  test "no switch when the first available login is the one recorded for the task" do
    @task.update_columns(credential_id: @claude_a.id)
    hold, = held_until_own_resets

    written = events_written { assert_completed(release_timer) }

    assert_equal [ [ "hold.closed", hold.id ] ], typed(written)
  end

  test "inside another command, as Timers applies it to a target task, it writes the same events as the app's" do
    hold, reset = held_until_own_resets
    written = events_written do
      ActiveRecord::Base.transaction(requires_new: true) do
        request = helper_request("report_request_result", {})
        ctx = scenario.context(request: request)
        entry = T::Entries::CredentialHoldRelease.new("credential_hold_release", targets: [ @task ])
        assert Leverage::Timers.apply(ctx, entry)
      end
    end

    assert_equal %w[hold.closed credential.switched], written.map(&:type)
    assert(written.all? { |event| [ event.actor_kind, event.actor_id, event.command_id ] == [ "app", nil, nil ] })
    assert_in_delta reset.to_f, written.first.effective_at.to_f, 0.000_001
    assert hold.reload.closed_at
  end

  test "the workspace sweep closes a due credential hold in Finishing and keeps its holder" do
    builder = scenario.seat(role: "builder", credential: @claude_a)
    task = scenario.finishing_task(builder: builder, actions: [ { kind: "send", state: "approved" } ])
    scenario.limit_credential(@claude_a, reset_at: from_now(3600))
    hold = scenario.hold(task, reason: "credential_limit", credential: @claude_a, item: false)
    @claude_a.update_columns(limited_until: last_effective_at(task))

    written = events_written do
      assert_equal({ "released_task_ids" => [ task.id ] }, assert_completed(release_timer).result)
    end

    assert_equal [ [ "hold.closed", hold.id ] ], typed(written)
    assert_equal [ "finishing", builder.id, @claude_a.id ], task.reload.attributes.values_at("state", "holder_seat_id", "credential_id")
  end

  test "a named task outside the timer's rows is refused" do
    ready = scenario.task(state: "ready")

    assert_refused("invalid_state", release_timer("task_id" => ready.id))
    assert_raises(T::NotFound) { release_timer("task_id" => SecureRandom.uuid) }
  end
end
