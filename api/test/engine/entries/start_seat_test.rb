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
end
