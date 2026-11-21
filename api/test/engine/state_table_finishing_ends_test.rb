require "test_helper"
require_relative "entries/jobs_support"

# Finishing rows for commands that end a lease, cancel a task or change
# the builder's availability. Actions and Finishing are exercised through
# their seams here. The integration tests exercise their writers.
class StateTableFinishingEndsTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario(lease_length_seconds: 600)
    @builder = running_seat
  end

  test "release in Finishing ends the lease and calls lose_builder with task.released" do
    task = finishing
    seat_hold = scenario.hold(task, reason: "seat_paused")
    key = new_key
    written = nil
    calls = recording_builder_loss do
      written = events_written do
        assert_completed(seat_command(@builder, "release", { "id" => task.id, "reason" => "unable_to_continue" }, key: key))
      end
    end

    row = finishing_row("release")
    assert_equal [ row.events.first, "hold.closed" ], written.map(&:type)
    assert_equal [ "seat", @builder.id, key, nil ],
      written.first.attributes.values_at("actor_kind", "actor_id", "command_id", "cause_id")
    assert_equal({ "reason" => "unable_to_continue", "wait_cause" => nil }, written.first.payload)
    assert_lost_lease(row, task)
    assert_equal 1, calls.size
    assert_lost_builder(calls.sole, task, written.first, actor: [ "seat", @builder.id ], key: key)
    assert_not_nil seat_hold.reload.closed_at
  end

  test "the sweep ends a Finishing lease and calls lose_builder as the app at the due time" do
    task = finishing
    due = Event.where(task_id: task.id).maximum(:effective_at)
    scenario.make_due(task, at: due)
    row = finishing_row("builder_lease_expiry")
    written = nil
    calls = recording_builder_loss do
      written = events_written do
        outcome = T.apply(T::Request.new(command: "builder_lease_expiry", workspace_id: scenario.workspace_id,
          caller_kind: nil, caller_id: nil, key: nil, request_hash: nil, params: {}))
        assert_equal({ "expired_task_ids" => [ task.id ] }, assert_completed(outcome).result)
      end
    end

    assert_equal [ row.events.first ], written.map(&:type)
    expired = written.sole
    assert_equal [ "app", nil, nil, due ], expired.attributes.values_at("actor_kind", "actor_id", "command_id", "effective_at")
    assert_equal({ "wait_cause" => nil }, expired.payload)
    assert_lost_lease(row, task)
    assert_equal 1, calls.size
    assert_lost_builder(calls.sole, task, expired, actor: [ "app", nil ], key: nil)
  end

  test "an inline expiry during heartbeat keeps the timer identity when the clock steps back" do
    task = finishing
    last = Event.where(task_id: task.id).order(:seq).last
    scenario.make_due(task, at: last.effective_at - 1)
    written = nil
    calls = recording_builder_loss do
      answering(Leverage::WorkspaceLock, :clock, -> { last.at - 1 }) do
        written = events_written { assert_refused("lease_expired", seat_command(@builder, "heartbeat", { "id" => task.id })) }
      end
    end

    assert_equal [ finishing_row("builder_lease_expiry").events.first ], written.map(&:type)
    expired = written.sole
    assert_operator expired.at, :>, last.at
    assert_equal [ "app", nil, nil, last.effective_at ],
      expired.attributes.values_at("actor_kind", "actor_id", "command_id", "effective_at")
    assert_equal 1, calls.size
    assert_lost_builder(calls.sole, task, expired, actor: [ "app", nil ], key: nil)
    assert_lost_lease(finishing_row("builder_lease_expiry"), task)
  end

  test "a Finishing heartbeat renews the holder's lease without writing an event" do
    task = finishing
    due = task.lease_due_at
    task.update_columns(lease_due_at: due - 60)

    assert_empty events_written {
      outcome = assert_completed(seat_command(@builder, "heartbeat", { "id" => task.id }))
      assert_equal task.reload.lease_due_at.utc.iso8601(6), outcome.result.fetch("lease_due_at")
    }
    assert_operator task.lease_due_at, :>=, due
    assert_equal [ "finishing", @builder.id ], task.attributes.values_at("state", "holder_seat_id")
  end

  test "cancel in Finishing calls revoke_open after task.cancelled and closes every hold" do
    task = finishing(state: "started")
    scenario.hold(task, reason: "owner_hold")
    action = Action.find_by!(task_id: task.id)
    scenario.hold(task, reason: "action_unconfirmed", facts: { "action_ids" => [ action.id ],
      "approved_by_kind" => "owner", "approved_by_id" => scenario.owner.id, "builder_announced_start" => true })
    key = new_key
    seen = []
    written = nil
    calls = answering(Leverage::Actions, :revoke_open, ->(ctx, asked) { seen << [ ctx.events.map(&:type), asked.state ] }) do
      written = events_written { assert_completed(owner_command("cancel", { "id" => task.id }, key: key)) }
    end

    row = finishing_row("cancel")
    assert_equal 1, calls.size
    ctx, asked = calls.sole.arguments
    assert_equal [ scenario.workspace_id, key, task.id ], [ ctx.workspace.id, ctx.request.key, asked.id ]
    assert_equal [ [ row.events, row.to ] ], seen
    assert_equal row.events + %w[hold.closed hold.closed inbox.resolved], written.map(&:type)
    assert_equal "cancel", written.last.payload.fetch("choice")
    assert_empty Leverage::Holds.open_holds(task)
    assert_equal [ row.to, nil, nil, nil, nil ], task.reload.attributes.values_at("state", "holder_seat_id",
      "builder_seat_id", "lease_due_at", "lease_time_left_while_paused")
  end

  test "cancel also calls revoke_open for a task cancelled before Finishing" do
    task = scenario.task(state: "ready", actions: [ { kind: "send" } ])
    calls = answering(Leverage::Actions, :revoke_open) do
      assert_completed(owner_command("cancel", { "id" => task.id }))
    end

    assert_equal [ task.id ], calls.map { |call| call.arguments[1].id }
  end

  { "change_seat" => [ { "enabled" => false }, "seat.changed" ], "remove_seat" => [ {}, "seat.removed" ] }.each do |command, (params, event)|
    test "#{command} calls lose_builder for the held task and each waiting task without clearing the holder" do
      waiting = Array.new(2) { finishing(holder: false) }
      held = finishing
      key = new_key
      written = nil
      calls = recording_builder_loss do
        waiting_calls = answering(Leverage::Finishing, :waiting_for, ->(_seat) { waiting }) do
          written = events_written { assert_completed(owner_command(command, params.merge("id" => @builder.id), key: key)) }
        end
        assert_equal [ @builder.id ], waiting_calls.map { |call| call.arguments.sole.id }
      end

      assert_equal [ event ], written.map(&:type)
      assert_equal [ held.id, *waiting.map(&:id) ].sort, calls.map { |call| call.arguments[1].id }.sort
      calls.each do |call|
        assert_lost_builder(call, call.arguments[1], written.sole, actor: [ "owner", scenario.owner.id ], key: key)
      end
      assert_equal [ "finishing", @builder.id, @builder.id ], held.reload.attributes.values_at("state", "holder_seat_id", "builder_seat_id")
      waiting.each { |task| assert_nil task.reload.holder_seat_id }
    end
  end

  test "a stopped run leaves a Finishing task, its lease and its holds alone" do
    task = finishing
    due = task.lease_due_at
    calls = answering(Leverage::Finishing, :lose_builder) do
      assert_empty events_written {
        assert_completed(helper_command("report_run_stopped", { "id" => @builder.id, "credential_id" => @builder.credential_id,
          "observed_at" => "2026-11-19T12:00:00Z", "stop_reason" => "stopped" }))
      }
    end

    assert_empty calls
    assert_empty Leverage::Holds.open_holds(task)
    assert_equal [ "stopped", nil, true ], @builder.reload.attributes.values_at("run_state", "run_credential_id", "wanted_running")
    assert_equal [ "finishing", @builder.id, due ], task.reload.attributes.values_at("state", "holder_seat_id", "lease_due_at")
  end

  private

  # Keep the post-command lease scan from granting a lease in cases
  # where the spy stands in for the hold that would prevent the grant.
  def recording_builder_loss(&block)
    calls = nil
    answering(Leverage::Finishing, :after_command) do
      calls = answering(Leverage::Finishing, :lose_builder, &block)
    end
    calls
  end

  def finishing(holder: true, state: "approved")
    scenario.finishing_task(builder: @builder, holder: holder, actions: [ { kind: "send", state: state } ])
  end

  def finishing_row(command) = StateTableCases.for([ command ]).find { |kase| kase.from == "finishing" }

  def assert_lost_lease(row, task)
    assert_equal [ row.to, @builder.id, nil, nil, nil, nil ], task.reload.attributes.values_at("state",
      "builder_seat_id", "holder_seat_id", "lease_due_at", "lease_time_left_while_paused", "resume_pending_since")
  end

  def assert_lost_builder(call, task, cause, actor:, key:)
    ctx, asked = call.arguments
    assert_equal [ scenario.workspace_id, task.id, cause.id, actor, key ],
      [ ctx.workspace.id, asked.id, call.keywords.fetch(:cause).id, ctx.actor, ctx.request.key ]
    assert_equal cause.effective_at, ctx.effective_at
  end
end
