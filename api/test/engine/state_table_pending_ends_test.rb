require "test_helper"
require_relative "entries/owner_controls_support"
require_relative "entries/pending_stub"

# What ends a builder's waiting command from outside (PRD L374-L380, L919;
# milestone 4 plan §2.1 rule 11, RE-4, RD-13; contract decisions SM-13,
# RC-17): the rows of rule 11's table that are WP5's. Each case gives the
# task a pending transition (Scenario's row) and runs the real command
# with PendingTransitions stubbed (PendingStub), and asserts that
# PendingTransitions.cancel was called once, with that transition and the
# row's code (one of RC-17's three), before the entry wrote any event of
# its own. What cancel itself does (the withdrawn checks and jobs, the
# closed holds, the refused command) is WP4's, in pending_transitions_test.rb.
#
#   What happens                                         Entry                 Code
#   The owner cancels the task                           cancel                task_cancelled
#   The builder's lease ends under a pending submit      builder_lease_expiry  lease_expired
#   The owner edits the contract                         edit_contract         invalid_state
#   The builder releases under a pending submit, or a
#   provisional claim                                    release               invalid_state
#   A hold opens on a Ready task with a provisional
#   claim                                                hold (Holds.open)     invalid_state
class StateTablePendingEndsTest < ActiveSupport::TestCase
  include OwnerControlsSupport
  include PendingStub

  setup do
    use_scenario(lease_length_seconds: 600)
    @builder = scenario.seat(role: "builder")
    @reviewer = scenario.seat(role: "reviewer")
  end

  # A task in state with the pending transition a waiting command of that
  # state leaves: Complete contract by the owner in the Backlog, a
  # provisional claim in Ready (RE-5: the claimant holds it, with no
  # lease), a submit in Working, a pass in review. Returns [task, pending].
  def waiting(state)
    case state
    when "backlog"
      task = scenario.task(state: "backlog")
      [ task, scenario.pending_transition(task, command: "complete_contract", requester: scenario.owner) ]
    when "ready" then provisional_claim
    when "working"
      task = scenario.task(state: "working", builder: @builder)
      [ task, scenario.pending_transition(task, command: "submit", requester: @builder) ]
    when "in_review"
      task = scenario.task(state: "in_review", builder: @builder)
      scenario.review(task, reviewer: @reviewer)
      [ task, scenario.pending_transition(task, command: "pass_review", requester: @reviewer) ]
    end
  end

  def provisional_claim
    task = scenario.task(state: "ready")
    task.update_columns(holder_seat_id: @builder.id)
    [ task, scenario.pending_transition(task, command: "claim", requester: @builder) ]
  end

  def seat_run(command, seat, params)
    key = new_key
    outcome = T.apply(request(command, params, key: key, caller_kind: "seat", caller_id: seat.id, scenario: scenario))
    [ outcome, written_by(key) ]
  end

  # The one call, its pending transition and code, and that the entry had
  # written none of its own events before it.
  def assert_cancelled_first(calls, pending, code, own_events)
    assert_equal [ [ :cancel, pending.id, code ] ], calls.map(&:summary)
    assert_empty calls.sole.written_before & own_events,
      "PendingTransitions.cancel is called before #{own_events.join(", ")} (rule 11)"
  end

  def edit_params(task)
    { "id" => task.id, "title" => task.title, "details" => nil,
      "criteria" => [ { "text" => "Made-up build criterion, changed.", "kind" => "build" },
                      { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }
  end

  %w[backlog ready working in_review].each do |state|
    test "the owner cancels a task with a pending transition from #{state}: task_cancelled, first" do
      task, pending = waiting(state)
      outcome = nil
      calls = with_pending(pending) { outcome, = owner_run("cancel", "id" => task.id) }

      assert_completed(outcome)
      assert_cancelled_first(calls, pending, "task_cancelled", %w[task.cancelled])
      assert_equal "cancelled", task.reload.state
    end

    test "the owner edits the contract of a task with a pending transition from #{state}: invalid_state, first" do
      task, pending = waiting(state)
      outcome = nil
      calls = with_pending(pending) { outcome, = owner_run("edit_contract", edit_params(task)) }

      assert_completed(outcome)
      assert_cancelled_first(calls, pending, "invalid_state", %w[task.contract_changed task.returned])
      assert_equal "backlog", task.reload.state
    end
  end

  test "the builder's lease ends under a pending submit: lease_expired, first, at the lease's due time by the app" do
    task, pending = waiting("working")
    due = scenario.database_now
    scenario.make_due(task, at: due)
    outcome = nil
    calls = with_pending(pending) do
      outcome = T.apply(T::Request.new(command: "builder_lease_expiry", workspace_id: scenario.workspace_id,
        caller_kind: nil, caller_id: nil, key: nil, request_hash: nil, params: { "task_id" => task.id }))
    end

    assert_completed(outcome)
    assert_cancelled_first(calls, pending, "lease_expired", %w[task.lease_expired])
    assert_equal({ effective_at: due, actor_kind: "app", actor_id: nil, command_id: nil }, calls.sole.keywords,
      "the withdrawals are the timer's: at the due time, by the app, with no key (traces 18, command 36)")
  end

  test "the lease ending inside the holder's own command gives the timer's time and actor, not the command's" do
    task, pending = waiting("working")
    due = scenario.database_now
    scenario.make_due(task, at: due)
    outcome = nil
    calls = with_pending(pending) { outcome, = seat_run("heartbeat", @builder, "id" => task.id) }

    assert_refused("lease_expired", outcome)
    assert_equal [ [ :cancel, pending.id, "lease_expired" ] ], calls.map(&:summary)
    assert_equal({ effective_at: due, actor_kind: "app", actor_id: nil, command_id: nil }, calls.sole.keywords)
  end

  test "the builder releases under a pending submit: invalid_state, first" do
    task, pending = waiting("working")
    outcome = nil
    calls = with_pending(pending) { outcome, = seat_run("release", @builder, "id" => task.id, "reason" => "stopping") }

    assert_completed(outcome)
    assert_cancelled_first(calls, pending, "invalid_state", %w[task.released])
    assert_equal [ "ready", nil ], task.reload.attributes.values_at("state", "holder_seat_id")
  end

  test "the claimant releases its provisional claim: invalid_state, first; the task stays Ready with no holder (SM-13)" do
    task, pending = provisional_claim
    outcome = nil
    events = nil
    calls = with_pending(pending) do
      outcome, events = seat_run("release", @builder, "id" => task.id, "reason" => "stopping")
    end

    assert_completed(outcome)
    assert_cancelled_first(calls, pending, "invalid_state", %w[task.released])
    assert_equal %w[task.released], events.map(&:type)
    assert_equal [ "ready", nil, nil ], task.reload.attributes.values_at("state", "holder_seat_id", "lease_due_at")
  end

  test "the owner holds a Ready task with a provisional claim: the claim is cancelled invalid_state, first (RD-13)" do
    task, pending = provisional_claim
    outcome = nil
    calls = with_pending(pending) { outcome, = owner_run("hold", "id" => task.id) }

    assert_completed(outcome)
    assert_cancelled_first(calls, pending, "invalid_state", %w[hold.opened])
    assert Hold.exists?(task_id: task.id, reason: "owner_hold", closed_at: nil)
  end

  test "a hold on a task with a pending submit cancels nothing: the transition waits under the hold (L378)" do
    task, pending = waiting("working")
    outcome = nil
    calls = with_pending(pending) { outcome, = owner_run("hold", "id" => task.id) }

    assert_completed(outcome)
    assert_empty calls
  end

  test "with no pending transition the four commands call nothing" do
    tasks = %w[backlog ready working].index_with { |state| scenario.task(state: state, builder: (@builder if state == "working")) }
    calls = with_pending(nil) do
      owner_run("hold", "id" => tasks.fetch("ready").id)
      owner_run("edit_contract", edit_params(tasks.fetch("backlog")))
      seat_run("release", @builder, "id" => tasks.fetch("working").id, "reason" => "stopping")
      owner_run("cancel", "id" => tasks.fetch("working").id)
    end

    assert_empty calls
  end
end
