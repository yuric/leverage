require "test_helper"
require_relative "accounts_support"

# report_request_progress (milestone 2 plan IN-23): one check's state while
# a run_add_checks or verify request runs, kept in helper_requests.progress
# for the app to follow with get_helper_request. It writes no event and
# moves updated_at, which the app's long poll compares (changed_after).
class ReportRequestProgressTest < ActiveSupport::TestCase
  include AccountsSupport

  setup do
    use_scenario
    @credential = @scenario.credential(added: false)
    @request = queue_request("run_add_checks", credential: @credential, state: "picked_up",
      params: { "provider" => "claude", "credential_kind" => "login" })
  end

  def progress(check, state, failure: nil, install: nil, request: @request, **options)
    helper_command("report_request_progress",
      { "id" => request.id, "check" => check, "state" => state, "failure" => failure, "install" => install }, **options)
  end

  test "each check's latest state is kept, in the order the checks were first reported, with no event" do
    written = events_written do
      assert_completed(progress("tool_installed", "running"))
      assert_completed(progress("tool_installed", "passed"))
      assert_completed(progress("signed_in", "waiting_for_sign_in"))
    end

    assert_empty written
    assert_equal [
      { "check" => "tool_installed", "state" => "passed", "failure" => nil, "install" => nil },
      { "check" => "signed_in", "state" => "waiting_for_sign_in", "failure" => nil, "install" => nil }
    ], @request.reload.progress
  end

  test "a report sets updated_at to the command's time" do
    before = @request.reload.updated_at
    assert_completed(progress("tool_installed", "running"))

    after = @request.reload.updated_at
    assert_operator after, :>, before
    assert_in_delta @scenario.database_now.to_f, after.to_f, 5
  end

  test "an install offer and a failure are kept as reported" do
    offer = { "installable" => true, "what" => "Made-up tool", "source_url" => "https://example.test/install.sh" }
    assert_completed(progress("tool_installed", "waiting_for_install", install: offer))
    assert_completed(progress("signed_in", "failed", failure: "not_signed_in"))

    assert_equal [ offer, nil ], @request.reload.progress.map { |entry| entry["install"] }
    assert_equal [ nil, "not_signed_in" ], @request.progress.map { |entry| entry["failure"] }
  end

  test "a failure on a check that has not failed is invalid" do
    assert_raises(T::Invalid) { progress("signed_in", "running", failure: "not_signed_in") }
  end

  test "a failed check with no failure code is invalid" do
    assert_raises(T::Invalid) { progress("signed_in", "failed") }
  end

  test "an install offer on another check is invalid" do
    offer = { "installable" => false, "what" => nil, "source_url" => nil }
    assert_raises(T::Invalid) { progress("signed_in", "waiting_for_sign_in", install: offer) }
  end

  test "a verify request takes progress too" do
    verify = queue_request("verify", credential: @scenario.credential(provider: "codex"))

    assert_completed(progress("signed_in", "running", request: verify))
    assert_equal 1, verify.reload.progress.size
  end

  test "a request with no checks is invalid_state" do
    seat = @scenario.seat(credential: @scenario.credential(provider: "codex"))
    start = queue_request("start_seat", seat: seat, state: "picked_up")

    assert_refused("invalid_state", progress("tool_installed", "running", request: start))
    assert_equal [], start.reload.progress
  end

  test "a request already finished is invalid_state" do
    @request.update_columns(state: "finished", finished_at: @scenario.database_now)

    assert_refused("invalid_state", progress("tool_installed", "running"))
  end

  test "an unknown request is not found" do
    assert_raises(T::NotFound) do
      helper_command("report_request_progress",
        { "id" => SecureRandom.uuid, "check" => "signed_in", "state" => "running", "failure" => nil, "install" => nil })
    end
  end
end
