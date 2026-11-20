require "test_helper"

# The seat_run_placement timer (milestone 3 plan HD-4; timers.json): a
# workspace timer every sweep fires, as the app. It writes no event. It
# moves the run of a running seat that holds nothing to its first available
# candidate, which is how an agent goes back to its own account once that
# has reset (L666); and it starts again a seat that is wanted running, whose
# last run ended for a limit or a sign-out, once the account its run belongs
# on is available. It leaves alone a seat stopped for any other reason
# (IN-30), a seat the owner stopped, and a seat that connects on its own.
class SeatRunPlacementTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @scenario.owner
    @own = @scenario.credential
    @below = @scenario.credential(provider: "codex")
  end

  def fire(scenario = @scenario)
    T.apply(T::Request.new(command: "seat_run_placement", workspace_id: scenario.workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: {}))
  end

  def starts(seat) = HelperRequest.where(seat_id: seat.id, kind: "start_seat").order(:requested_at, :id).to_a

  def later = @scenario.database_now + 3600

  # A seat whose last run ended for reason, with no run now.
  def ended_seat(reason, wanted_running: true, credential: @own)
    seat = @scenario.seat(credential: credential, wanted_running: wanted_running)
    seat.update!(run_state: "stopped", run_credential_id: nil, run_stop_reason: reason, token_hash: nil)
    seat
  end

  def fired
    before = Workspace.find(@scenario.workspace_id).last_seq
    outcome = fire
    assert outcome.completed?, "expected completed, got #{outcome.outcome} #{outcome.refusal&.code}"
    assert_equal before, Workspace.find(@scenario.workspace_id).last_seq, "the timer writes no event"
    outcome
  end

  test "an idle running seat whose run is on a lower login goes back to its own once that has reset (L666)" do
    seat = @scenario.seat(credential: @own, wanted_running: true)
    @scenario.run(seat, on: @below)

    fired

    start = starts(seat).sole
    assert_equal [ @own.id, "queued" ], [ start.credential_id, start.state ]
    assert_equal({ "role" => "builder", "provider" => "claude", "model" => "made-up-model", "effort" => nil }, start.params)
  end

  test "an idle running seat whose own login is limited moves to the first available one below" do
    seat = @scenario.seat(credential: @own, wanted_running: true)
    @scenario.run(seat)
    @scenario.limit_credential(@own, reset_at: later)

    fired

    assert_equal [ @below.id ], starts(seat).map(&:credential_id)
  end

  test "a running seat already on its first available login, or with none available, is left alone" do
    on_first = @scenario.seat(credential: @own, wanted_running: true)
    @scenario.run(on_first)
    other_own = @scenario.credential(provider: "grok")
    nowhere = @scenario.seat(credential: other_own, wanted_running: true)
    @scenario.run(nowhere)
    @scenario.limit_credential(other_own, reset_at: later)

    fired

    assert_empty starts(on_first)
    assert_empty starts(nowhere), "a login after its own is a candidate only when it is after it in the order"
  end

  test "a running seat that holds a task or a review is not moved" do
    builder = @scenario.seat(credential: @own, wanted_running: true)
    @scenario.task(state: "working", builder: builder)
    @scenario.run(builder, on: @below)
    reviewer = @scenario.seat(role: "reviewer", credential: @own, wanted_running: true)
    @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)
    @scenario.run(reviewer, on: @below)

    fired

    assert_empty starts(builder)
    assert_empty starts(reviewer)
  end

  test "a seat stopped for a limit is started again once an account is available, on the first available one" do
    seat = ended_seat("limit")
    @scenario.limit_credential(@own, reset_at: later)

    fired
    assert_equal [ @below.id ], starts(seat).map(&:credential_id)

    fired
    assert_equal 1, starts(seat).size, "no second start while the first is unfinished"
  end

  test "a seat stopped for a sign-out is started again too, and not while every candidate is out" do
    seat = ended_seat("signed_out")
    @own.update!(state: "signed_out")
    @scenario.limit_credential(@below, reset_at: later)

    fired
    assert_empty starts(seat), "no candidate is available"

    @below.update!(limited_since: nil, limited_until: nil)
    fired
    assert_equal [ @below.id ], starts(seat).map(&:credential_id)
  end

  test "a seat stopped for a limit that holds a task continues it on the task's credential, naming it" do
    seat = ended_seat("limit")
    task = @scenario.task(state: "working", builder: seat)
    task.update!(credential_id: @below.id)

    fired

    start = starts(seat).sole
    assert_equal [ @below.id, task.id ], [ start.credential_id, start.params.fetch("task_id") ]
  end

  test "a seat whose task waits under a credential hold is left to the hold" do
    seat = ended_seat("limit")
    task = @scenario.task(state: "working", builder: seat)
    @scenario.limit_credential(@own, reset_at: later, seat: seat, task: task)
    @scenario.hold(task, reason: "credential_limit", credential: @own, item: false)

    fired

    assert_empty starts(seat)
  end

  test "a seat stopped for an error, one the owner stopped, and one that connects on its own are left alone" do
    failing = ended_seat("error")
    finished = ended_seat("finished")
    stopped = ended_seat("limit", wanted_running: false)
    alone = @scenario.seat(provider: "codex")
    removed = @scenario.remove(ended_seat("limit"))

    fired

    [ failing, finished, stopped, alone, removed ].each { |seat| assert_empty starts(seat), seat.run_stop_reason.to_s }
  end

  test "a seat whose new run's token is already issued is not started again" do
    seat = ended_seat("limit")
    @scenario.run(seat, on: @own, state: "stopped")

    fired

    assert_empty starts(seat)
  end

  test "it looks only at its own workspace" do
    other = Scenario.new
    seat = other.seat(credential: other.credential, wanted_running: true)
    seat.update!(run_state: "stopped", run_credential_id: nil, run_stop_reason: "limit")

    fired

    assert_empty starts(seat)
  end
end
