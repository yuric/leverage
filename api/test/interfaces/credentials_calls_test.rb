require "test_helper"

# Test the owner HTTP boundary independently of the credential entries (WP5).
class CredentialsCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @owner_token = @scenario.owner_token
    @credential_id = SecureRandom.uuid
    @request_ids = { "helper_request_ids" => [ SecureRandom.uuid, SecureRandom.uuid ] }
    @stand_in = T::StandIn.new
  end

  test "rename forwards the path id and name and renders completed and duplicate name outcomes" do
    body = { "name" => "Renamed account" }
    assert_command("/#{@credential_id}/rename", "rename_credential", body: body,
      params: body.merge("id" => @credential_id), refusal: "duplicate_name")
  end

  test "remove takes no body and renders completed and credential in use outcomes" do
    assert_command("/#{@credential_id}/remove", "remove_credential", params: { "id" => @credential_id }, refusal: "credential_in_use")
  end

  test "reorder forwards the ids in the order the owner sent" do
    body = { "order" => [ SecureRandom.uuid, @credential_id ] }
    assert_command("/order", "reorder_credentials", body: body, params: body)
  end

  test "refresh takes no body and answers the helper request ids" do
    assert_command("/refresh", "refresh_usage", result: @request_ids)
  end

  test "verify all runs verify_credential without an id and answers the helper request ids" do
    assert_command("/verify-all", "verify_credential", result: @request_ids)
  end

  test "the owner operations authenticate before checking the body" do
    [ "/#{@credential_id}/rename", "/#{@credential_id}/remove", "/order", "/refresh", "/verify-all" ].each do |suffix|
      send_call(suffix, body: { "unexpected" => true }, token: @scenario.helper_token)

      assert_transport_error :unauthorized, "unauthenticated"
    end
  end

  test "rename and reorder reject invalid bodies before running a command" do
    send_call("/not-an-id/rename", body: { "name" => "" })
    assert_transport_error :unprocessable_content, "invalid"

    send_call("/order", body: { "order" => [] })
    assert_transport_error :unprocessable_content, "invalid"
  end

  test "remove, refresh and verify all reject an unexpected body" do
    [ "/#{@credential_id}/remove", "/refresh", "/verify-all" ].each do |suffix|
      send_call(suffix, body: { "id" => @credential_id })

      assert_transport_error :unprocessable_content, "invalid"
    end
  end

  test "rename and remove reject a path id that is not a UUID" do
    send_call("/not-an-id/rename", body: { "name" => "Renamed account" })
    assert_transport_error :not_found, "not_found"

    send_call("/not-an-id/remove")
    assert_transport_error :not_found, "not_found"
  end

  private

  def path(suffix) = "/v1/owner/credentials#{suffix}"

  def send_call(suffix, body: nil, token: @owner_token, key: "credential-call")
    T.with_stand_in(@stand_in) do
      post path(suffix), params: (JSON.generate(body) if body),
        headers: { "Authorization" => "Bearer #{token}", "Idempotency-Key" => key, "Content-Type" => "application/json" }
    end
  end

  def assert_command(suffix, command, body: nil, params: {}, result: nil, refusal: "invalid_state")
    assert_request_matches_contract("POST", path(suffix), body)
    @stand_in.script(command, T::Outcome.completed(result))
    send_call(suffix, body: body, key: "completed")

    assert_response :ok
    assert_response_matches_contract
    assert_equal({ "key" => "completed", "command" => command, "outcome" => "completed", "result" => result, "refusal" => nil },
      response.parsed_body)

    @stand_in.script(command, T::Outcome.refused(T::Refusal.new(code: refusal)))
    send_call(suffix, body: body, key: "refused")

    assert_response :conflict
    assert_response_matches_contract
    assert_equal "refused", response.parsed_body["outcome"]
    assert_equal refusal, response.parsed_body.dig("refusal", "code")

    assert_equal %w[completed refused], @stand_in.requests.map(&:key)
    @stand_in.requests.each do |command_request|
      assert_equal [ command, @scenario.workspace_id, "owner", @scenario.owner.id ],
        [ command_request.command, command_request.workspace_id, command_request.caller_kind, command_request.caller_id ]
      assert_equal params, command_request.params
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: path(suffix), body: (JSON.generate(body) if body).to_s),
        command_request.request_hash
    end
  end

  def assert_transport_error(status, code)
    assert_response status
    assert_response_matches_contract
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_empty @stand_in.requests
  end
end
