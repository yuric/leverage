require "test_helper"

# The owner's sign-in over HTTP (milestone 2 plan IN-2, IN-4, IN-5, IN-9,
# IN-13): get_setup_state, create_owner, sign_in_owner and sign_out_owner,
# through the real pipeline, each request and response checked against
# openapi.json.
class OwnerSessionTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  PASSWORD = "made-up-password-1".freeze
  EMAIL = "owner@example.test".freeze

  # Committed tests of other files may have left an owner in this worker's
  # database; inside this test's transaction there is none.
  setup do
    Session.delete_all
    User.delete_all
  end

  def body(email: EMAIL, password: PASSWORD) = { "email_address" => email, "password" => password }

  def post_json(path, payload, key: "key-#{SecureRandom.hex(4)}", token: nil)
    headers = { "Content-Type" => "application/json" }
    headers["Idempotency-Key"] = key if key
    headers["Authorization"] = "Bearer #{token}" if token
    assert_request_matches_contract("POST", path, payload) if payload
    post path, params: payload && JSON.generate(payload), headers: headers
  end

  def create_owner(key: "setup-1", **fields) = post_json("/v1/owner/setup", body(**fields), key: key)

  def sign_in(key: "sign-in-#{SecureRandom.hex(4)}", **fields) = post_json("/v1/owner/session", body(**fields), key: key)

  def sign_out(token, key: "sign-out-#{SecureRandom.hex(4)}") = post_json("/v1/owner/session/sign-out", nil, key: key, token: token)

  def result = response.parsed_body.fetch("result")

  def assert_transport_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_response_matches_contract
  end

  test "setup state says whether the owner exists" do
    get "/v1/owner/setup"
    assert_response :ok
    assert_equal({ "owner_exists" => false }, response.parsed_body)
    assert_response_matches_contract

    create_owner
    get "/v1/owner/setup"
    assert_equal({ "owner_exists" => true }, response.parsed_body)
    assert_response_matches_contract
  end

  test "setup works once: the token comes once, a repeat answers without it, a new key is 404" do
    create_owner
    assert_response :ok
    assert_response_matches_contract
    assert_equal [ "setup-1", "create_owner", "completed", nil ],
      response.parsed_body.values_at("key", "command", "outcome", "refusal")
    token = result.fetch("session_token")
    user = User.find_by!(email_address: EMAIL)
    assert_equal user.id, result.fetch("user_id")
    assert_equal user.id, Leverage::Tokens.find(token, kind: :owner).id

    create_owner
    assert_response :ok
    assert_response_matches_contract
    assert_equal({ "user_id" => user.id, "created_at" => result.fetch("created_at"), "repeated" => true }, result)

    counts = [ Workspace.count, User.count, Session.count, Command.count ]
    create_owner(key: "setup-2")
    assert_transport_error(:not_found, "not_found")
    create_owner(key: "setup-3", email: "other@example.test")
    assert_transport_error(:not_found, "not_found")
    assert_equal counts, [ Workspace.count, User.count, Session.count, Command.count ]
  end

  test "setup refuses a password shorter than 8 characters and a body the contract refuses" do
    create_owner(password: "short-7")
    assert_transport_error(:unprocessable_entity, "invalid")

    post "/v1/owner/setup", params: '{"email_address":"owner@example.test"', headers: { "Idempotency-Key" => "setup-x",
      "Content-Type" => "application/json" }
    assert_transport_error(:bad_request, "malformed")

    post "/v1/owner/setup", params: JSON.generate(body.merge("extra" => 1)), headers: { "Idempotency-Key" => "setup-y",
      "Content-Type" => "application/json" }
    assert_transport_error(:unprocessable_entity, "invalid")

    create_owner(key: nil)
    assert_transport_error(:bad_request, "malformed")
    assert_equal 0, User.count
  end

  test "sign-in answers a session once and the repeat without it" do
    create_owner
    sign_in(key: "sign-in-1")
    assert_response :ok
    assert_response_matches_contract
    assert_equal "sign_in", response.parsed_body.fetch("command")
    token = result.fetch("session_token")
    assert Leverage::Tokens.find(token, kind: :owner)

    sign_in(key: "sign-in-1")
    assert_response :ok
    assert_response_matches_contract
    assert_equal true, result.fetch("repeated")
    refute result.key?("session_token")
  end

  test "a wrong password or an unknown address is 401 and stores no commands row" do
    create_owner
    commands = Command.count

    sign_in(password: "made-up-wrong-password")
    assert_transport_error(:unauthorized, "unauthenticated")
    sign_in(email: "nobody@example.test")
    assert_transport_error(:unauthorized, "unauthenticated")
    assert_equal commands, Command.count

    sign_in(key: "sign-in-1")
    assert_response :ok
    sign_in(key: "sign-in-1", password: "made-up-wrong-password")
    assert_transport_error(:unauthorized, "unauthenticated")
  end

  # PRD, Security: wrong passwords are counted (Leverage::Http::SignInThrottle).
  test "after ten wrong passwords the right one is refused 401 for a minute, and opens no session" do
    create_owner
    10.times do
      sign_in(password: "made-up-wrong-password")
      assert_transport_error(:unauthorized, "unauthenticated")
      assert_equal "The email address or the password is not right", response.parsed_body.dig("error", "message")
    end
    counts = [ Session.count, Command.count ]

    sign_in
    assert_transport_error(:unauthorized, "unauthenticated")
    assert_equal "Too many wrong sign-ins. Wait a minute and try again", response.parsed_body.dig("error", "message")
    assert_equal counts, [ Session.count, Command.count ]

    travel 61.seconds
    sign_in
    assert_response :ok
    assert Leverage::Tokens.find(result.fetch("session_token"), kind: :owner)
  end

  test "a session that is already open keeps working while sign-in is refused" do
    create_owner
    token = result.fetch("session_token")
    10.times { sign_in(password: "made-up-wrong-password") }
    sign_in
    assert_transport_error(:unauthorized, "unauthenticated")

    get "/v1/owner/session", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :ok
  end

  # Setup compares the password too, to recognise a repeat by the owner.
  # Once an owner exists its wrong passwords are counted with sign-in's,
  # and while sign-in is refused it compares nothing: every key is 404.
  test "wrong passwords sent to setup count, and setup compares none while sign-in is refused" do
    create_owner
    10.times do |index|
      create_owner(key: "setup-wrong-#{index}", password: "made-up-wrong-password")
      assert_transport_error(:not_found, "not_found")
    end

    sign_in
    assert_transport_error(:unauthorized, "unauthenticated")
    create_owner
    assert_transport_error(:not_found, "not_found")

    travel 61.seconds
    create_owner
    assert_response :ok
    assert_equal true, result.fetch("repeated")
  end

  test "wrong sign-ins before any owner exists do not stop the owner from being created" do
    11.times { sign_in(password: "made-up-wrong-password") }
    assert_transport_error(:unauthorized, "unauthenticated")

    create_owner
    assert_response :ok
    assert result.fetch("session_token")
  end

  test "two sign-ins that differ only in the password store the same request hash, which leaves the password out" do
    create_owner
    sign_in(key: "sign-in-a")
    assert_response :ok

    User.find_by!(email_address: EMAIL).update!(password: "made-up-password-2")
    sign_in(key: "sign-in-b", password: "made-up-password-2")
    assert_response :ok

    one, two = %w[sign-in-a sign-in-b].map { |key| Command.find_by!(key: key) }
    assert_equal one.request_hash, two.request_hash
    with_password = Leverage::Idempotency.request_hash(method: "POST", path: "/v1/owner/session", body: JSON.generate(body))
    refute_equal with_password, one.request_hash

    sign_in(key: "sign-in-a", password: "made-up-password-2")
    assert_response :ok
    assert_equal true, result.fetch("repeated"), "the same key with another (right) password is a repeat, not key_reused"
  end

  test "sign-out ends the session; its token and a repeat of the key answer 401" do
    create_owner
    token = result.fetch("session_token")
    sign_in
    other = result.fetch("session_token")

    sign_out(token, key: "sign-out-1")
    assert_response :ok
    assert_response_matches_contract
    assert_equal [ "sign_out", "completed" ], response.parsed_body.values_at("command", "outcome")
    assert_nil Leverage::Tokens.find(token, kind: :owner)
    assert Leverage::Tokens.find(other, kind: :owner), "only the session the token named ends"

    counts = [ Command.count, Session.count ]
    sign_out(token, key: "sign-out-1")
    assert_transport_error(:unauthorized, "unauthenticated")
    sign_out(token)
    assert_transport_error(:unauthorized, "unauthenticated")
    assert_equal counts, [ Command.count, Session.count ]
  end

  test "a revoked session cannot read the owner identity" do
    create_owner
    token = result.fetch("session_token")
    sign_out(token)
    assert_response :ok

    get "/v1/owner/session", headers: { "Authorization" => "Bearer #{token}" }
    assert_transport_error(:unauthorized, "unauthenticated")
    refute_includes response.body, EMAIL
  end

  test "sign-out needs the owner's session and a key" do
    scenario = Scenario.new
    sign_out(nil)
    assert_transport_error(:unauthorized, "unauthenticated")
    sign_out(scenario.helper_token)
    assert_transport_error(:unauthorized, "unauthenticated")
    sign_out(scenario.token_for(scenario.seat))
    assert_transport_error(:unauthorized, "unauthenticated")

    sign_out(scenario.owner_token, key: nil)
    assert_transport_error(:bad_request, "malformed")
  end

  test "neither the password nor the token is in the stored rows" do
    create_owner
    token = result.fetch("session_token")
    sign_in
    second = result.fetch("session_token")

    stored = Command.all.to_a.to_json
    [ PASSWORD, token, second ].each { |secret| refute_includes stored, secret }
    refute_includes User.find_by!(email_address: EMAIL).password_digest, PASSWORD
  end
end
