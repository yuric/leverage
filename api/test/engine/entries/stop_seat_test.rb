require "test_helper"
require_relative "accounts_support"

# stop_seat (PRD L590; milestone 2 plan IN-17, IN-23, IN-30): a seat the
# app runs is no longer wanted running and a stop_seat request is queued;
# no event. Its token ends when the helper reports the run stopped.
class StopSeatTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "it clears wanted running and queues stop_seat, with no event, and the token lasts until the run stops" do
    seat = running_seat
    written = events_written { @outcome = assert_completed(owner_command("stop_seat", { "id" => seat.id })) }

    assert_empty written
    seat.reload
    assert_equal [ false, "running" ], [ seat.wanted_running, seat.run_state ]
    request = HelperRequest.find(@outcome.result.fetch("helper_request_id"))
    assert_equal [ "stop_seat", "queued", seat.id, seat.credential_id, {} ],
      [ request.kind, request.state, request.seat_id, request.credential_id, request.params ]
    assert signs_in?(seat)
  end

  test "a seat that connects on its own is not the app's to stop" do
    assert_refused("invalid_state", owner_command("stop_seat", { "id" => own_seat.id }))
  end

  test "a removed seat is not found" do
    seat = @scenario.remove(running_seat)

    assert_raises(T::NotFound) { owner_command("stop_seat", { "id" => seat.id }) }
  end
end
