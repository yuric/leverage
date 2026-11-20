require "test_helper"
require_relative "accounts_support"

# report_run_started (milestone 2 plan IN-23; RunStartedReport): a run
# started on a seat the app runs. It updates seats.run_state only and writes
# no event.
class ReportRunStartedTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  def report(seat, credential_id: seat.credential_id)
    helper_command("report_run_started", { "id" => seat.id, "credential_id" => credential_id,
      "observed_at" => "2026-11-19T12:00:00Z", "tool_version" => "9.9.9-made-up" })
  end

  test "it marks the run running and writes no event" do
    seat = @scenario.seat(credential: @scenario.credential, run_state: "stopped", wanted_running: true)
    digest = seat.token_hash
    written = events_written { assert_completed(report(seat)) }

    assert_empty written
    seat.reload
    assert_equal [ "running", true, digest ], [ seat.run_state, seat.wanted_running, seat.token_hash ]
  end

  test "a run on a credential other than the seat's is invalid in this milestone" do
    seat = @scenario.seat(credential: @scenario.credential, run_state: "stopped")

    assert_raises(T::Invalid) { report(seat, credential_id: @scenario.credential(provider: "codex").id) }
    assert_equal "stopped", seat.reload.run_state
  end

  test "a seat that connects on its own has no run the app starts" do
    seat = own_seat

    assert_refused("invalid_state", report(seat, credential_id: SecureRandom.uuid))
  end

  test "an unknown seat is not found" do
    assert_raises(T::NotFound) do
      helper_command("report_run_started", { "id" => SecureRandom.uuid, "credential_id" => SecureRandom.uuid,
        "observed_at" => "2026-11-19T12:00:00Z", "tool_version" => "9.9.9-made-up" })
    end
  end
end
