require "test_helper"
require_relative "accounts_support"

# start_seat (PRD L590-L591; milestone 2 plan IN-23, IN-30): a seat the app
# runs is marked wanted running and a start_seat request is queued; no
# event. The token is issued when the helper picks the request up.
class StartSeatTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "it marks the seat wanted running and queues start_seat with the seat's inputs, with no event" do
    seat = @scenario.seat(role: "builder", credential: @scenario.credential, model: "made-up-model", effort: "",
      run_state: "stopped", wanted_running: false, token: false)
    written = events_written { @outcome = assert_completed(owner_command("start_seat", { "id" => seat.id })) }

    assert_empty written
    assert seat.reload.wanted_running
    request = HelperRequest.find(@outcome.result.fetch("helper_request_id"))
    assert_equal [ "start_seat", "queued", seat.id, seat.credential_id ],
      [ request.kind, request.state, request.seat_id, request.credential_id ]
    assert_equal({ "role" => "builder", "provider" => "claude", "model" => "made-up-model", "effort" => nil }, request.params)
    assert_nil seat.token_hash, "the token waits for the helper's pickup"
  end

  test "a start while another start is unfinished answers that request and queues none" do
    seat = @scenario.seat(credential: @scenario.credential, run_state: "stopped")
    first = assert_completed(owner_command("start_seat", { "id" => seat.id }))

    second = assert_completed(owner_command("start_seat", { "id" => seat.id }))

    assert_equal first.result, second.result
    assert_equal 1, HelperRequest.where(seat_id: seat.id, kind: "start_seat").count
  end

  test "a seat that connects on its own is not the app's to start" do
    seat = own_seat

    assert_refused("invalid_state", owner_command("start_seat", { "id" => seat.id }))
    assert_not seat.reload.wanted_running
  end

  test "a removed seat is not found" do
    seat = @scenario.remove(@scenario.seat(credential: @scenario.credential))

    assert_raises(T::NotFound) { owner_command("start_seat", { "id" => seat.id }) }
  end

  test "a seat of another workspace is not found" do
    other = Scenario.new
    seat = other.seat(credential: other.credential)

    assert_raises(T::NotFound) { owner_command("start_seat", { "id" => seat.id }) }
  end

  # A start the helper picked up but never reported on, followed by the
  # owner's Stop, is stale: the next Start must not answer it, or Start
  # would do nothing until the helper's next token. It is failed, as a new
  # helper token fails it, and a new request is queued that the helper's
  # next call hands out.
  test "after a start whose result was never reported and a stop, a start queues a new request the helper is handed" do
    seat = @scenario.seat(credential: @scenario.credential, run_state: "stopped")
    first = HelperRequest.find(assert_completed(owner_command("start_seat", { "id" => seat.id })).result.fetch("helper_request_id"))
    first.update!(state: "picked_up", picked_up_at: @scenario.database_now)
    seat.update!(run_state: "running")
    assert_completed(owner_command("stop_seat", { "id" => seat.id }))
    HelperRequest.where(seat_id: seat.id, kind: "stop_seat").update_all(state: "done", finished_at: @scenario.database_now)
    assert_completed(helper_command("report_run_stopped", { "id" => seat.id, "credential_id" => seat.credential_id,
      "observed_at" => Time.current.utc.iso8601, "stop_reason" => "stopped" }))

    again = assert_completed(owner_command("start_seat", { "id" => seat.id }))

    fresh = HelperRequest.find(again.result.fetch("helper_request_id"))
    assert_not_equal first.id, fresh.id
    assert_equal "queued", fresh.state
    assert_equal [ "failed", Leverage::Transitions::Entries::IssueHelperToken::FAILED_RESULT ],
      first.reload.attributes.values_at("state", "result")
    assert_equal fresh.id, Leverage::Reads::HelperNext.call(@scenario.workspace_id)&.id
  end

  test "a second start while the first is picked up and the seat is still wanted running answers the first" do
    seat = @scenario.seat(credential: @scenario.credential, run_state: "stopped")
    first = assert_completed(owner_command("start_seat", { "id" => seat.id }))
    HelperRequest.find(first.result.fetch("helper_request_id")).update!(state: "picked_up",
      picked_up_at: @scenario.database_now)

    second = assert_completed(owner_command("start_seat", { "id" => seat.id }))

    assert_equal first.result, second.result
    assert_equal 1, HelperRequest.where(seat_id: seat.id, kind: "start_seat").count
  end

end
