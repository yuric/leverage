require "test_helper"

# The helper reports a contract-shaped reading to the credential in its path.
class ReadingsCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @helper = @scenario.helper
    @helper_token = @scenario.helper_token
    @credential_id = SecureRandom.uuid
    @stand_in = T::StandIn.new
  end

  test "a report forwards the reading and the path id and renders completed and refused outcomes" do
    body = reading.merge("figures" => Array.new(32, figure("F" * 80)))
    assert_request_matches_contract("POST", path, body)
    @stand_in.script("report_reading", T::Outcome.completed(nil))
    send_reading(body, key: "completed")

    assert_response :ok
    assert_response_matches_contract
    assert_equal({ "key" => "completed", "command" => "report_reading", "outcome" => "completed", "result" => nil, "refusal" => nil },
      response.parsed_body)

    @stand_in.script("report_reading", T::Outcome.refused(T::Refusal.new(code: "invalid_state")))
    send_reading(body, key: "refused")

    assert_response :conflict
    assert_response_matches_contract
    assert_equal "refused", response.parsed_body["outcome"]
    assert_equal "invalid_state", response.parsed_body.dig("refusal", "code")

    assert_equal %w[completed refused], @stand_in.requests.map(&:key)
    @stand_in.requests.each do |command_request|
      assert_equal [ "report_reading", @scenario.workspace_id, "helper", @helper.id ],
        [ command_request.command, command_request.workspace_id, command_request.caller_kind, command_request.caller_id ]
      assert_equal body.merge("id" => @credential_id), command_request.params
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: path, body: JSON.generate(body)), command_request.request_hash
    end
  end

  test "a reading with 33 figures is invalid before a command runs" do
    send_reading(reading.merge("figures" => Array.new(33, figure("Five hours"))))

    assert_transport_error :unprocessable_content, "invalid"
  end

  test "a figure label with 81 characters is invalid before a command runs" do
    send_reading(reading.merge("figures" => [ figure("F" * 81) ]))

    assert_transport_error :unprocessable_content, "invalid"
  end

  test "an owner cannot report a reading" do
    send_reading(reading, token: @scenario.owner_token)

    assert_transport_error :unauthorized, "unauthenticated"
  end

  test "the path id must be a UUID even when the body is valid" do
    send_reading(reading, credential_id: "not-an-id")

    assert_transport_error :not_found, "not_found"
  end

  test "the entry receives both ids so it can reject a reading for a different credential" do
    other_id = SecureRandom.uuid
    @stand_in.script("report_reading") { raise T::Invalid, "Reading credential does not match the path" }
    send_reading(reading, credential_id: other_id)

    assert_response :unprocessable_content
    assert_response_matches_contract
    assert_equal "invalid", response.parsed_body.dig("error", "code")
    assert_equal [ other_id, @credential_id ], @stand_in.requests.sole.params.values_at("id", "credential_id")
  end

  private

  def path(id = @credential_id) = "/v1/helper/credentials/#{id}/readings"

  def reading
    { "credential_id" => @credential_id, "observed_at" => "2026-01-01T00:00:00Z", "state" => "ok",
      "tool_version" => nil, "figures" => [], "resets" => nil }
  end

  def figure(label)
    { "label" => label, "kind" => "limit", "window" => "five_hour", "percent_used" => 40, "reset_at" => nil, "value" => nil }
  end

  def send_reading(body, credential_id: @credential_id, token: @helper_token, key: "reading-call")
    T.with_stand_in(@stand_in) do
      post path(credential_id), params: JSON.generate(body),
        headers: { "Authorization" => "Bearer #{token}", "Idempotency-Key" => key, "Content-Type" => "application/json" }
    end
  end

  def assert_transport_error(status, code)
    assert_response status
    assert_response_matches_contract
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_empty @stand_in.requests
  end
end
