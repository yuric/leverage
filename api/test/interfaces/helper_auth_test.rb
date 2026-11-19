require "test_helper"

# The helper's sign-in and the owner's call that issues the helper's token
# (milestone 2 plan IN-13, IN-17, IN-18): the helper's three seat calls
# (issue_seat_token, report_run_started, report_run_stopped) take only the
# helper's current token, and issue_helper_token takes only the owner's
# session. The entries of the two run reports and of issue_helper_token
# are another package's, so those calls run against Transitions::StandIn.
class HelperAuthTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @credential = @scenario.credential
    @seat = @scenario.seat(credential: @credential)
    @start = HelperRequest.create!(workspace_id: @scenario.workspace_id, kind: "start_seat", seat_id: @seat.id,
      state: "picked_up", requested_at: @scenario.database_now, params: { "role" => "builder", "provider" => "claude" })
    @stand_in = T::StandIn.new
    @stand_in.script("report_run_started", T::Outcome.completed({}))
    @stand_in.script("report_run_stopped", T::Outcome.completed({}))
    @stand_in.script("issue_helper_token", T::Outcome.completed({ "helper_id" => SecureRandom.uuid }))
  end

  def started = { "credential_id" => @credential.id, "observed_at" => "2026-01-01T00:00:00Z", "tool_version" => "0.0.0-made-up" }

  def stopped = { "credential_id" => @credential.id, "observed_at" => "2026-01-01T00:00:00Z", "stop_reason" => "stopped" }

  # [path, body] of each helper call.
  def helper_calls
    [ [ "/v1/helper/requests/#{@start.id}/seat-token", nil ], [ "/v1/helper/seats/#{@seat.id}/run-started", started ],
      [ "/v1/helper/seats/#{@seat.id}/run-stopped", stopped ] ]
  end

  def call(path, body, token)
    headers = { "Idempotency-Key" => "key-#{SecureRandom.hex(4)}", "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{token}" if token
    post path, params: body && JSON.generate(body), headers: headers
  end

  def assert_unauthenticated
    assert_response :unauthorized
    assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
    assert_response_matches_contract
  end

  test "every helper call is 401 without the helper's current token, and nothing runs" do
    ended = Scenario.new
    ended_token = ended.helper_token
    ended.end_token(ended.helper)
    T.with_stand_in(@stand_in) do
      helper_calls.each do |path, body|
        [ nil, @scenario.owner_token, @scenario.token_for(@seat), ended_token, "lvh_#{"B" * 43}", "not-a-token" ].each do |token|
          call(path, body, token)
          assert_unauthenticated
        end
      end
    end
    assert_empty @stand_in.requests
  end

  test "the helper's token reaches the run reports, with the seat and the body" do
    T.with_stand_in(@stand_in) do
      call("/v1/helper/seats/#{@seat.id}/run-started", started, @scenario.helper_token)
      assert_response :ok
      assert_response_matches_contract
      call("/v1/helper/seats/#{@seat.id}/run-stopped", stopped, @scenario.helper_token)
      assert_response :ok
      assert_response_matches_contract
    end

    first, second = @stand_in.requests
    assert_equal [ "report_run_started", "helper", @scenario.helper.id, @scenario.workspace_id ],
      [ first.command, first.caller_kind, first.caller_id, first.workspace_id ]
    assert_equal started.merge("id" => @seat.id), first.params
    assert_equal stopped.merge("id" => @seat.id), second.params
  end

  test "a run report the contract refuses is 422, and an id that is not a UUID is 404, after the sign-in" do
    T.with_stand_in(@stand_in) do
      call("/v1/helper/seats/#{@seat.id}/run-stopped", stopped.merge("stop_reason" => "made-up"), @scenario.helper_token)
      assert_response :unprocessable_entity
      assert_response_matches_contract
      call("/v1/helper/seats/not-a-uuid/run-started", started, @scenario.helper_token)
      assert_response :not_found
      call("/v1/helper/seats/not-a-uuid/run-started", started, nil)
      assert_response :unauthorized
    end
    assert_empty @stand_in.requests
  end

  test "issue_helper_token takes the owner's session only" do
    T.with_stand_in(@stand_in) do
      [ nil, @scenario.helper_token, @scenario.token_for(@seat) ].each do |token|
        call("/v1/owner/helpers", { "name" => "Made-up Mac" }, token)
        assert_unauthenticated
      end
      assert_empty @stand_in.requests

      call("/v1/owner/helpers", { "name" => "Made-up Mac" }, @scenario.owner_token)
      assert_response :ok
    end
    request = @stand_in.requests.sole
    assert_equal [ "issue_helper_token", "owner", @scenario.owner.id, { "name" => "Made-up Mac" } ],
      [ request.command, request.caller_kind, request.caller_id, request.params ]
  end
end
