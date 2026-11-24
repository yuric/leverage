require "test_helper"
require_relative "../support/http_calls"

class LandingPromptTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner_token
    @seat = @scenario.seat
  end

  test "HTTP and MCP prompts use the request address and only the issued token" do
    host! "leverage.example.test:41320"
    address = "http://leverage.example.test:41320"
    %w[http mcp].each do |connection|
      issue(connection: connection)
      assert_response :ok
      assert_response_matches_contract

      result = response.parsed_body.fetch("result")
      seat_token = result.fetch("seat_token")
      assert_match Leverage::Tokens::FORM, seat_token
      assert_equal [ @seat.id, connection ], result.values_at("seat_id", "connection")
      join = "#{address}/v1/join"
      join += "?connection=mcp" if connection == "mcp"
      assert_equal "Join Leverage at #{address} with token #{seat_token}. " \
        "Fetch GET #{join} with header Authorization: Bearer #{seat_token} and follow its instructions exactly.", result.fetch("text")
      assert_equal [ seat_token ], result.fetch("text").scan(/lv[sho]_[A-Za-z0-9_-]{43}/).uniq
    end
  end

  test "an unusable host is malformed and leaves the seat token in place" do
    original = @seat.token_hash
    host! "leverage.example.test;unsafe"
    assert_no_difference -> { Command.count } do
      issue
      assert_response :bad_request
    end

    assert_response_matches_contract
    assert_equal "malformed", response.parsed_body.dig("error", "code")
    assert_equal original, @seat.reload.token_hash
    refute_includes response.body, "unsafe"
  end

  test "native seats conflict and removed, foreign and unknown seats are not found" do
    native = @scenario.seat(credential: @scenario.credential)
    issue(seat_id: native.id)
    assert_response :conflict
    assert_response_matches_contract
    assert_equal "invalid_state", response.parsed_body.dig("refusal", "code")

    removed = @scenario.seat
    @scenario.remove(removed)
    foreign = Scenario.new.seat
    [ removed.id, foreign.id, SecureRandom.uuid, "not-a-uuid" ].each do |seat_id|
      issue(seat_id: seat_id)
      assert_response :not_found
      assert_response_matches_contract
      assert_equal "not_found", response.parsed_body.dig("error", "code")
    end
  end

  test "only the owner can issue the prompt and the old GET route is gone" do
    [ nil, @scenario.token_for(@seat), @scenario.helper_token ].each do |token|
      issue(token: token)
      assert_response :unauthorized
      assert_response_matches_contract
    end

    get HttpCalls.path("issue_landing_prompt", { "id" => @seat.id }), headers: { "Authorization" => "Bearer #{@owner}" }
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
  end

  private

  def issue(connection: "http", seat_id: @seat.id, token: @owner)
    call("issue_landing_prompt", token: token, key: new_key, ids: { "id" => seat_id }, body: { "connection" => connection })
  end
end
