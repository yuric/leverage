require "test_helper"
require_relative "entries/owner_controls_support"
require_relative "entries/pending_ends_support"

# Test 3 (PRD L836) for the commands that end a reviewer's or a seat's
# waiting command (milestone 4 plan WP5b, §2.1 rule 11): for each row of
# rule 11's table that is theirs, the command is run through the real
# pipeline on a task whose pending transition it takes away, and the test
# asserts the call to PendingTransitions.cancel, the code it gives (always
# one of RC-17's three), that the call comes before the events the row names
# for the thing taken away, and that those events are then written. What
# the call does is WP4's (pending_transitions_test.rb). The commands whose
# rows list a withdrawn check as a side event come from state_machine.json,
# so a row the table adds or drops makes the test of the list fail.
class StateTableReviewAndSeatEndsTest < ActiveSupport::TestCase
  include OwnerControlsSupport
  include PendingEndsSupport

  # The commands of this package whose rows withdraw a check, and the rows
  # of rule 11's table they are (the code each gives).
  ENDS = {
    "release_review" => "invalid_state",
    "review_lease_expiry" => "lease_expired",
    "report_run_stopped" => "invalid_state",
    "issue_helper_token" => "invalid_state",
    "pause_seat" => "invalid_state",
    "change_seat" => "invalid_state",
    "remove_seat" => "invalid_state"
  }.freeze

  CODES = %w[task_cancelled lease_expired invalid_state].freeze

  setup do
    use_scenario(lease_length_seconds: 600)
    @login = scenario.credential
  end

  test "the commands that withdraw a check are the seven this file proves, and each code is one of RC-17's three" do
    withdrawing = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
      .select { |row| row.fetch("side_events").any? { |side| side.fetch("event") == "check.finished" } }
      .map { |row| row.fetch("command") }.uniq

    assert_equal [], ENDS.keys - withdrawing, "a command here whose rows no longer withdraw a check"
    assert_empty ENDS.values - CODES
  end

  test "release_review: the reviewer's pending pass, invalid_state, before review.released" do
    reviewer, review, pending = reviewer_under_pass
    calls, events = run_recording { seat_run("release_review", reviewer, "id" => review.id) }

    assert_cancelled(calls, pending, "release_review", events_before: [])
    assert_equal %w[review.released], events.map(&:type)
  end

  test "review_lease_expiry: the pending pass under the lease that ends, lease_expired, before review.lease_expired" do
    _, review, pending = reviewer_under_pass
    scenario.make_due(review)
    calls, events = run_recording do
      outcome = T.apply(T::Request.new(command: "review_lease_expiry", workspace_id: scenario.workspace_id, caller_kind: nil,
        caller_id: nil, key: nil, request_hash: nil, params: { "review_id" => review.id }))
      [ outcome, Event.where(workspace_id: scenario.workspace_id, type: "review.lease_expired").to_a ]
    end

    assert_cancelled(calls, pending, "review_lease_expiry", events_before: [])
    assert_equal %w[review.lease_expired], events.map(&:type)
  end

  test "report_run_stopped: the pending pass of the review the stopped run held, invalid_state, before review.released" do
    reviewer, = reviewer_under_pass(running: true)
    pending = PendingTransition.find_by!(requester_id: reviewer.id)
    calls, events = run_recording do
      helper_run("report_run_stopped", "id" => reviewer.id, "credential_id" => reviewer.run_credential_id,
        "observed_at" => "2026-11-19T12:00:00Z", "stop_reason" => "stopped")
    end

    assert_cancelled(calls, pending, "report_run_stopped", events_before: [])
    assert_equal %w[review.released], events.map(&:type)
  end

  test "issue_helper_token: a run treated as stopped, the pending pass of its review, invalid_state, before review.released" do
    reviewer, = reviewer_under_pass(running: true)
    pending = PendingTransition.find_by!(requester_id: reviewer.id)
    calls, events = run_recording { owner_run("issue_helper_token", "name" => "Made-up Mac") }

    assert_cancelled(calls, pending, "issue_helper_token", events_before: [])
    assert_equal %w[review.released], events.map(&:type)
  end

  test "remove_seat: a pending submit, a pending pass and a provisional claim, each invalid_state, before what is released" do
    builder = scenario.seat(role: "builder", credential: @login)
    submit = scenario.pending_transition(scenario.task(state: "working", builder: builder), command: "submit", requester: builder)
    reviewer, = reviewer_under_pass
    pass = PendingTransition.find_by!(requester_id: reviewer.id)
    claimant = scenario.seat(role: "builder", credential: @login)
    claim = provisional_claim(claimant)

    { builder => [ submit, %w[seat.removed task.released] ], reviewer => [ pass, %w[seat.removed review.released] ],
      claimant => [ claim, %w[seat.removed] ] }.each do |seat, (pending, written)|
      calls, events = run_recording { owner_run("remove_seat", "id" => seat.id) }

      assert_cancelled(calls, pending, "remove_seat", events_before: %w[seat.removed])
      assert_equal written, events.map(&:type)
    end
  end

  test "change_seat: a change that disables the seat cancels a pending submit and a provisional claim, not a pending pass" do
    builder = scenario.seat(role: "builder", credential: @login)
    submit = scenario.pending_transition(scenario.task(state: "working", builder: builder), command: "submit", requester: builder)
    claimant = scenario.seat(role: "builder", credential: @login)
    claim = provisional_claim(claimant)
    reviewer, = reviewer_under_pass

    { builder => [ submit, %w[seat.changed task.released] ], claimant => [ claim, %w[seat.changed] ] }
      .each do |seat, (pending, written)|
      calls, events = run_recording { owner_run("change_seat", "id" => seat.id, "enabled" => false) }

      assert_cancelled(calls, pending, "change_seat", events_before: %w[seat.changed])
      assert_equal written, events.map(&:type)
    end

    calls, events = run_recording { owner_run("change_seat", "id" => reviewer.id, "enabled" => false) }
    assert_empty calls
    assert_equal %w[seat.changed], events.map(&:type)
  end

  test "pause_seat: a provisional claim is cancelled with invalid_state and no hold opens; a pending submit is kept" do
    claimant = scenario.seat(role: "builder", credential: @login)
    claim = provisional_claim(claimant)
    calls, events = run_recording { owner_run("pause_seat", "id" => claimant.id) }

    assert_cancelled(calls, claim, "pause_seat", events_before: %w[seat.paused])
    assert_equal %w[seat.paused], events.map(&:type)

    builder = scenario.seat(role: "builder", credential: @login)
    submit = scenario.pending_transition(scenario.task(state: "working", builder: builder), command: "submit", requester: builder)
    calls, events = run_recording { owner_run("pause_seat", "id" => builder.id) }

    assert_empty calls
    assert_equal %w[seat.paused hold.opened], events.map(&:type)
    assert_equal "pending", submit.reload.state
  end

  private

  # A reviewer holding the review of an In review task under its pending
  # pass. Returns the reviewer, the review and the PendingTransition.
  def reviewer_under_pass(running: false)
    reviewer = scenario.seat(role: "reviewer", credential: @login, run_state: (running ? "running" : "stopped"),
      wanted_running: running)
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)
    [ reviewer, review, scenario.pending_transition(task, command: "pass_review", requester: reviewer) ]
  end

  # A Ready task a seat holds provisionally, under its pending claim.
  def provisional_claim(seat)
    task = scenario.task(state: "ready")
    task.update!(holder_seat_id: seat.id)
    scenario.pending_transition(task, command: "claim", requester: seat)
  end

  # Runs the block, which returns [outcome, events] or an owner_run's pair;
  # returns the cancel calls and the events.
  def run_recording
    result = nil
    calls = recording_cancels { result = yield }
    outcome, events = result
    assert outcome.completed?, "expected completed, got #{outcome.outcome} #{outcome.refusal&.code}"
    [ calls, events ]
  end

  def assert_cancelled(calls, pending, command, events_before:)
    assert_equal [ Cancelled.new(pending.id, ENDS.fetch(command), events_before) ], calls
  end

  def seat_run(command, seat, params)
    key = new_key
    outcome = T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
    [ outcome, written_by(key) ]
  end

  def helper_run(command, params)
    key = new_key
    [ helper_command(command, params, key: key), written_by(key) ]
  end
end
