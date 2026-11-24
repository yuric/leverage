require "test_helper"

# A token is shown once (milestone 2 plan §2.1, IN-9, IN-11): the first
# answer of a key carries it in `result` (OwnerSession, SeatTokenPickup,
# HelperTokenIssued), and a repeat of the key answers the contract's
# *Repeated result, with `repeated: true` and no token. Every response is
# checked against openapi.json. Sign-in, setup and the seat-token pickup
# run the real entries; issue_helper_token's entry is another package's,
# so its call runs against Transitions::StandIn scripted the way the
# pipeline answers: the token in `once` the first time, none on a repeat.
class TokenOnceTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  setup do
    Session.delete_all
    User.delete_all
  end

  def post_json(path, payload, key:, token: nil)
    headers = { "Content-Type" => "application/json", "Idempotency-Key" => key }
    headers["Authorization"] = "Bearer #{token}" if token
    post path, params: payload && JSON.generate(payload), headers: headers
    assert_response_matches_contract
    response.parsed_body
  end

  def assert_once(first, repeat, field, ids)
    assert_equal "completed", first.fetch("outcome")
    assert_match Leverage::Tokens::FORM, first.dig("result", field)
    assert_equal ids.sort, (first.fetch("result").keys - [ field ]).sort
    refute first.fetch("result").key?("repeated")

    assert_equal "completed", repeat.fetch("outcome")
    refute repeat.fetch("result").key?(field), "a repeat never carries #{field}"
    assert_equal true, repeat.dig("result", "repeated")
    assert_equal first.fetch("result").except(field), repeat.fetch("result").except("repeated")
    refute_includes repeat.to_json, first.dig("result", field)
  end

  test "create_owner: OwnerSession once, then OwnerSessionRepeated" do
    payload = { "email_address" => "owner@example.test", "password" => "made-up-password-1" }
    first = post_json("/v1/owner/setup", payload, key: "setup-once")
    repeat = post_json("/v1/owner/setup", payload, key: "setup-once")

    assert_matches_component("OwnerSession", first.fetch("result"))
    assert_matches_component("OwnerSessionRepeated", repeat.fetch("result"))
    assert_once(first, repeat, "session_token", %w[user_id created_at])
  end

  test "sign_in: OwnerSession once, then OwnerSessionRepeated" do
    scenario = Scenario.new
    payload = { "email_address" => scenario.owner.email_address, "password" => Scenario::PASSWORD }
    first = post_json("/v1/owner/session", payload, key: "sign-in-once")
    repeat = post_json("/v1/owner/session", payload, key: "sign-in-once")

    assert_matches_component("OwnerSession", first.fetch("result"))
    assert_matches_component("OwnerSessionRepeated", repeat.fetch("result"))
    assert_once(first, repeat, "session_token", %w[user_id created_at])
  end

  test "connect returns the same seat id for both connections without issuing a token" do
    scenario = Scenario.new
    [ nil, scenario.credential.id ].each do |credential_id|
      body = { "name" => "Made-up agent", "role" => "general", "provider" => (credential_id ? nil : "codex"),
        "credential_id" => credential_id }
      key = "connect-#{credential_id || "prompt"}"
      first = post_json("/v1/owner/seats", body, key: key, token: scenario.owner_token)
      assert_response :ok
      assert_equal [ "seat_id" ], first.fetch("result").keys
      assert_nil Seat.find(first.dig("result", "seat_id")).token_hash

      repeat = post_json("/v1/owner/seats", body, key: key, token: scenario.owner_token)
      assert_response :ok
      assert_equal first, repeat
    end
  end

  test "issue_landing_prompt shows the prompt once and stored reads never disclose it" do
    scenario = Scenario.new
    seat = scenario.seat
    path = "/v1/owner/seats/#{seat.id}/landing-prompt"
    key = "prompt-once"
    body = { "connection" => "mcp" }
    first = post_json(path, body, key: key, token: scenario.owner_token)
    assert_response :ok
    assert_matches_component("LandingPromptIssued", first.fetch("result"))
    assert_match Leverage::Tokens::FORM, first.dig("result", "seat_token")
    assert_includes first.dig("result", "text"), first.dig("result", "seat_token")

    repeat = post_json(path, body, key: key, token: scenario.owner_token)
    assert_response :ok
    assert_matches_component("LandingPromptIssuedRepeated", repeat.fetch("result"))
    assert_equal first.fetch("result").except("seat_token", "text").merge("repeated" => true), repeat.fetch("result")

    get "/v1/owner/commands/#{key}", headers: { "Authorization" => "Bearer #{scenario.owner_token}" }
    assert_response :ok
    assert_response_matches_contract
    assert_equal repeat, response.parsed_body
  end

  test "issue_seat_token: SeatTokenPickup once, then SeatTokenPickupRepeated" do
    scenario = Scenario.new
    seat = scenario.seat(credential: scenario.credential, token: false)
    start = HelperRequest.create!(workspace_id: scenario.workspace_id, kind: "start_seat", seat_id: seat.id,
      state: "picked_up", requested_at: scenario.database_now)
    path = "/v1/helper/requests/#{start.id}/seat-token"
    first = post_json(path, nil, key: "pickup-once", token: scenario.helper_token)
    repeat = post_json(path, nil, key: "pickup-once", token: scenario.helper_token)

    assert_matches_component("SeatTokenPickup", first.fetch("result"))
    assert_matches_component("SeatTokenPickupRepeated", repeat.fetch("result"))
    assert_once(first, repeat, "seat_token", %w[helper_request_id seat_id])
    assert_equal({ "helper_request_id" => start.id, "seat_id" => seat.id }, repeat.fetch("result").except("repeated"))
  end

  test "issue_helper_token: HelperTokenIssued once, then HelperTokenIssuedRepeated" do
    scenario = Scenario.new
    helper_id = SecureRandom.uuid
    made_up = Leverage::Tokens.issue(:helper)
    answers = [ T::Outcome.completed({ "helper_id" => helper_id }, once: { "helper_token" => made_up }),
                T::Outcome.completed({ "helper_id" => helper_id }) ]
    stand_in = T::StandIn.new.script("issue_helper_token") { |_request| answers.shift }

    first = repeat = nil
    T.with_stand_in(stand_in) do
      first = post_json("/v1/owner/helpers", { "name" => "Made-up Mac" }, key: "helper-once", token: scenario.owner_token)
      repeat = post_json("/v1/owner/helpers", { "name" => "Made-up Mac" }, key: "helper-once", token: scenario.owner_token)
    end

    assert_matches_component("HelperTokenIssued", first.fetch("result"))
    assert_matches_component("HelperTokenIssuedRepeated", repeat.fetch("result"))
    assert_once(first, repeat, "helper_token", %w[helper_id])
  end

  test "a refused pickup answers the refusal and no token" do
    scenario = Scenario.new
    seat = scenario.seat(credential: scenario.credential)
    start = HelperRequest.create!(workspace_id: scenario.workspace_id, kind: "start_seat", seat_id: seat.id,
      state: "picked_up", requested_at: scenario.database_now)
    scenario.remove(seat)

    answer = post_json("/v1/helper/requests/#{start.id}/seat-token", nil, key: "pickup-refused", token: scenario.helper_token)

    assert_response :conflict
    assert_equal [ "refused", nil, "invalid_state" ], [ answer.fetch("outcome"), answer.fetch("result"), answer.dig("refusal", "code") ]
    refute_match(/lvs_/, answer.to_json)
  end
end
