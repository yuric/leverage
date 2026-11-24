require "test_helper"
require_relative "../support/http_calls"

# No secret is kept or written where it does not belong (PRD L823; milestone
# 2 plan IN-9, IN-11, IN-17, IN-18): a session, a seat and a helper token is
# stored only as its SHA-256 digest; a seat token ends at the next issue;
# no token and no password appears in a commands row, a helper_requests
# row or any log line written during the test; and the landing prompt of a
# seat that connects on its own carries no token of any kind and nothing
# shaped like one (override 11).
#
# The landing-prompt case needs Reads::LandingPrompt, which is WP9's: it is
# red until WP9 lands and first passes in WP17's whole-suite run.
class SecretsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  T = Leverage::Transitions

  # Anything shaped like a token of any kind (IN-18).
  TOKEN_SHAPE = /lv[sho]_[A-Za-z0-9_-]{20,}/
  PASSWORD = "made-up-password-1".freeze

  setup do
    Session.delete_all
    User.delete_all
    @log = StringIO.new
    @capture = ActiveSupport::Logger.new(@log)
    @capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(@capture)
  end

  teardown do
    Rails.logger.stop_broadcasting_to(@capture)
  end

  def post_json(path, payload, key: "key-#{SecureRandom.hex(4)}", token: nil)
    headers = { "Content-Type" => "application/json", "Idempotency-Key" => key }
    headers["Authorization"] = "Bearer #{token}" if token
    post path, params: payload && JSON.generate(payload), headers: headers
    response.parsed_body
  end

  # Everything the database keeps that a secret could leak into.
  def stored_rows
    [ Command.all.to_a, HelperRequest.all.to_a, Event.all.to_a ].to_json
  end

  def assert_nowhere(secret, what)
    refute_includes stored_rows, secret, "#{what} is in a commands, helper_requests or events row"
    refute_includes @log.string, secret, "#{what} is in a log line"
  end

  # Signs up, signs in, picks a seat's token up twice and has a helper token
  # issued (against the stand-in); returns the tokens each first answer
  # carried.
  def exercise
    owner_token = post_json("/v1/owner/setup", { "email_address" => "owner@example.test", "password" => PASSWORD })
      .dig("result", "session_token")
    second_session = post_json("/v1/owner/session", { "email_address" => "owner@example.test", "password" => PASSWORD })
      .dig("result", "session_token")
    user = User.find_by!(email_address: "owner@example.test")
    workspace_id = user.workspace_id

    helper_token = Leverage::Tokens.issue(:helper)
    helper = Helper.create!(workspace_id: workspace_id, name: "Made-up Mac", token_hash: Leverage::Tokens.digest(helper_token))
    credential = Credential.create!(workspace_id: workspace_id, kind: "login", provider: "claude", name: "Made-up account",
      position: 1, state: "active")
    seat = Seat.create!(workspace_id: workspace_id, role: "builder", credential_id: credential.id, provider: "claude",
      name: "Made-up builder", model: "", effort: "", strength_rank: 1)
    start = HelperRequest.create!(workspace_id: workspace_id, kind: "start_seat", seat_id: seat.id, state: "picked_up",
      requested_at: Time.current, params: { "role" => "builder", "provider" => "claude" })
    path = "/v1/helper/requests/#{start.id}/seat-token"
    first_seat = post_json(path, nil, token: helper_token).dig("result", "seat_token")
    second_seat = post_json(path, nil, token: helper_token).dig("result", "seat_token")

    issued = Leverage::Tokens.issue(:helper)
    stand_in = T::StandIn.new.script("issue_helper_token",
      T::Outcome.completed({ "helper_id" => helper.id }, once: { "helper_token" => issued }))
    T.with_stand_in(stand_in) { post_json("/v1/owner/helpers", { "name" => "Made-up Mac" }, token: owner_token) }
    issued_answer = response.parsed_body.dig("result", "helper_token")

    { owner: owner_token, second_session: second_session, first_seat: first_seat, second_seat: second_seat,
      helper: helper_token, issued: issued_answer, seat: seat, user: user }
  end

  test "every token is stored only as its digest" do
    tokens = exercise

    assert_equal Leverage::Tokens.digest(tokens.fetch(:second_seat)), tokens.fetch(:seat).reload.token_hash
    sessions = Session.where(user_id: tokens.fetch(:user).id).pluck(:token_hash)
    assert_equal [ tokens.fetch(:owner), tokens.fetch(:second_session) ].map { |t| Leverage::Tokens.digest(t) }.sort, sessions.sort
    (Session.pluck(:token_hash) + Seat.where.not(token_hash: nil).pluck(:token_hash) + Helper.pluck(:token_hash)).each do |hash|
      assert_match(/\A\h{64}\z/, hash, "a stored token column holds a SHA-256 hex digest only")
    end
  end

  test "a seat token ends at the next issue" do
    tokens = exercise

    assert_nil Leverage::Tokens.find(tokens.fetch(:first_seat), kind: :seat)
    assert_equal tokens.fetch(:seat).id, Leverage::Tokens.find(tokens.fetch(:second_seat), kind: :seat).id
  end

  test "no token and no password is in a stored row or a log line" do
    tokens = exercise

    assert_includes @log.string, "leverage.command command=sign_in", "the log was captured"
    tokens.slice(:owner, :second_session, :first_seat, :second_seat, :helper, :issued).each do |name, token|
      assert_match TOKEN_SHAPE, token, "#{name} was returned"
      assert_nowhere(token, name)
    end
    assert_nowhere(PASSWORD, "the password")
    refute_match TOKEN_SHAPE, stored_rows
    refute_match TOKEN_SHAPE, @log.string
  end

  test "a token-shaped value sent in any field is filtered out of the request log" do
    stray = Leverage::Tokens.issue(:seat)
    post_json("/v1/owner/session", { "email_address" => "owner@example.test", "password" => PASSWORD, "note" => stray })

    assert_response :unprocessable_entity
    assert_includes @log.string, "Parameters", "the request's parameters were logged"
    refute_includes @log.string, stray
    refute_includes @log.string, PASSWORD
  end

  test "the landing prompt of a seat that connects on its own carries no token" do
    scenario = Scenario.new
    seat = scenario.seat(role: "builder", provider: "claude")
    seat_token = scenario.token_for(seat)

    get "/v1/owner/seats/#{seat.id}/landing-prompt", headers: { "Authorization" => "Bearer #{scenario.owner_token}" }

    assert_response :ok
    assert_response_matches_contract
    text = response.body
    refute_includes text, seat_token
    refute_includes text, scenario.owner_token
    refute_includes text, scenario.helper_token
    refute_match TOKEN_SHAPE, text
    refute_match(/\blv[sho]_/, text, "nothing shaped like a token, not even a prefix")
  end

  test "credential operations keep account facts off the log and credentials off the wire" do
    scenario = Scenario.new
    credential = scenario.token_credential
    request = scenario.helper_request(kind: "verify", credential: credential, state: "picked_up")
    name = "00000000-0000-4000-8000-00000000f00a"
    plan = "00000000-0000-4000-8000-00000000f00b"
    email = "made-up-account@example.test"
    marker = "LVRG-TOKEN-00000000f00c"
    result = { "result" => { "outcome" => "finished", "tool_version" => nil, "plan" => plan, "account_email" => email,
      "checks" => [ { "check" => "token_works", "passed" => true, "failure" => nil } ] } }
    reading = { "credential_id" => credential.id, "observed_at" => scenario.database_now.utc.iso8601(6),
      "state" => "ok", "tool_version" => nil, "figures" => [], "resets" => nil }
    ids = { "id" => credential.id }

    call("report_reading", token: scenario.helper_token, key: new_key, ids: ids,
      body: reading.merge("unexpected" => "sk-#{marker}"), check_request: false)
    assert_response :unprocessable_content
    assert_response_matches_contract
    assert_private_response(marker, email, plan, name)

    calls = [
      [ "report_request_result", scenario.helper_token, { "id" => request.id }, result ],
      [ "rename_credential", scenario.owner_token, ids, { "name" => name } ],
      [ "report_reading", scenario.helper_token, ids, reading ],
      [ "refresh_usage", scenario.owner_token, {}, nil ],
      [ "verify_all_credentials", scenario.owner_token, {}, nil ],
      [ "reorder_credentials", scenario.owner_token, {}, { "order" => [ credential.id ] } ]
    ]
    calls.each do |operation, token, path_ids, body|
      call(operation, token: token, key: new_key, ids: path_ids, body: body)
      assert_response :ok
      assert_response_matches_contract
      assert_private_response(marker, email, plan, name)
    end
    assert_equal [ nil, nil ], request.reload.result.values_at("plan", "account_email")

    call("list_credentials", token: scenario.owner_token)
    assert_response :ok
    assert_response_matches_contract
    listed = response.parsed_body.fetch("credentials").sole.fetch("credential")
    assert listed.values_at("name", "plan", "account_email") == [ name, plan, email ], "the owner sees the account facts"
    assert_equal "••••••••", listed.fetch("masked_label")
    assert_private_response(marker)

    call("get_helper_request", token: scenario.owner_token, ids: { "id" => request.id }, query: { "wait" => 0 })
    assert_response :ok
    assert_response_matches_contract
    assert_private_response(marker, email, plan, name)
    call("remove_credential", token: scenario.owner_token, key: new_key, ids: ids)
    assert_response :ok
    assert_response_matches_contract
    assert_private_response(marker, email, plan, name)

    assert @log.string.include?("Parameters"), "the request parameters were logged"
    { marker: marker, email: email, plan: plan, name: name }.each do |field, value|
      refute @log.string.include?(value), "#{field} reached the request log"
      refute stored_rows.include?(value), "#{field} reached a command, helper request or event"
    end
  end

  private

  def assert_private_response(*values)
    values.each { |value| refute response.body.include?(value), "a private value reached the response" }
    refute TOKEN_SHAPE.match?(response.body), "a Leverage token reached the response"
  end
end
