require "test_helper"

# The calls the handoff adds, over HTTP (milestone 3 plan WP7, §2.3, HE-8,
# HE-9, HE-36): the helper's two reports, report_limit and report_signed_out,
# and the owner's Sign in again. One request per operation with
# Transitions::StandIn scripted to complete and to refuse, each request and
# each response held to openapi.json by OpenapiAssertions. A controller only
# signs the caller in, checks the body against its schema, builds a Request
# and renders the Outcome; what the entries do is proven where the entries
# are (the credential's id is the path's, under the param "id", as every
# command's is).
class HandoffCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @helper = @scenario.helper
    @helper_token = @scenario.helper_token
    @owner = @scenario.owner
    @owner_token = @scenario.owner_token
    @stand_in = T::StandIn.new
    @credential_id = SecureRandom.uuid
    @seat_id = SecureRandom.uuid
    @task_id = SecureRandom.uuid
    @request_id = SecureRandom.uuid
  end

  def limit_body
    { "credential_id" => @credential_id, "seat_id" => @seat_id, "task_id" => @task_id, "review_id" => nil, "job_id" => nil,
      "window" => "five_hour", "reset_at" => "2026-01-01T05:00:00Z", "observed_at" => "2026-01-01T00:00:00Z",
      "tool_version" => "0.0.0-made-up" }
  end

  def signed_out_body
    limit_body.slice("credential_id", "seat_id", "task_id", "review_id", "job_id", "observed_at", "tool_version")
  end

  # The operation, the command it runs, who calls it, the path, the body
  # and the token-free result the scripted entry answers.
  def calls
    [
      { op: "report_limit", command: "report_limit", caller: "helper", path: "/v1/helper/credentials/#{@credential_id}/limit-reached",
        body: limit_body, result: nil },
      { op: "report_signed_out", command: "report_signed_out", caller: "helper",
        path: "/v1/helper/credentials/#{@credential_id}/signed-out", body: signed_out_body, result: nil },
      { op: "sign_in_again", command: "sign_in_again", caller: "owner", path: "/v1/owner/credentials/#{@credential_id}/sign-in",
        body: nil, result: { "helper_request_id" => @request_id } }
    ]
  end

  def token_of(call) = call[:caller] == "helper" ? @helper_token : @owner_token

  def headers(call, key: "handoff-key-1", token: token_of(call))
    { "Authorization" => ("Bearer #{token}" if token), "Idempotency-Key" => key }.compact
  end

  def send_call(call, key: "handoff-key-1", token: token_of(call), body: call[:body], raw: nil, path: call[:path])
    payload = raw || (body && JSON.generate(body))
    if payload.nil?
      post path, headers: headers(call, key: key, token: token)
    else
      post path, params: payload, headers: headers(call, key: key, token: token).merge("Content-Type" => "application/json")
    end
  end

  def with_stand_in(&block) = T.with_stand_in(@stand_in, &block)

  def assert_transport_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
    assert_empty @stand_in.requests, "no command may run"
  end

  test "each call runs its entry for its caller and answers the completed outcome with its result" do
    calls.each do |call|
      stand_in = T::StandIn.new
      stand_in.script(call[:command], T::Outcome.completed(call[:result]))
      assert_request_matches_contract("POST", call[:path], call[:body])

      T.with_stand_in(stand_in) { send_call(call, key: "key-#{call[:op]}") }

      assert_response :ok, "#{call[:op]}: #{response.body}"
      assert_response_matches_contract
      body = response.parsed_body
      assert_equal({ "key" => "key-#{call[:op]}", "command" => call[:command], "outcome" => "completed", "refusal" => nil },
        body.slice("key", "command", "outcome", "refusal"), call[:op])
      call[:result] ? assert_equal(call[:result], body["result"], call[:op]) : assert_nil(body["result"], call[:op])

      request = stand_in.requests.sole
      assert_equal call[:command], request.command
      assert_equal @scenario.workspace_id, request.workspace_id
      assert_equal call[:caller], request.caller_kind
      assert_equal (call[:caller] == "helper" ? @helper.id : @owner.id), request.caller_id
      assert_equal "key-#{call[:op]}", request.key
      assert_equal (call[:body] || {}).merge("id" => @credential_id), request.params, call[:op]
      raw = call[:body] && JSON.generate(call[:body])
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: call[:path], body: raw.to_s), request.request_hash
    end
  end

  test "each call answers a refusal as 409 with the refusal in the outcome" do
    calls.each do |call|
      stand_in = T::StandIn.new
      stand_in.script(call[:command], T::Outcome.refused(T::Refusal.new(code: "invalid_state")))

      T.with_stand_in(stand_in) { send_call(call, key: "refused-#{call[:op]}") }

      assert_response :conflict, call[:op]
      assert_response_matches_contract
      assert_equal "refused", response.parsed_body["outcome"]
      assert_nil response.parsed_body["result"]
      assert_equal "invalid_state", response.parsed_body.dig("refusal", "code")
    end
  end

  test "a pending outcome is 202" do
    call = calls.first
    @stand_in.script("report_limit", T::Outcome.new(outcome: :pending))
    with_stand_in { send_call(call) }

    assert_response :accepted
  end

  test "a report that names a job reaches the entry, which answers its 404" do
    call = calls.first
    body = limit_body.merge("task_id" => nil, "job_id" => SecureRandom.uuid)
    @stand_in.script("report_limit") { |_request| raise T::NotFound, "No such job" }
    with_stand_in { send_call(call, body: body) }

    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
    assert_equal body.merge("id" => @credential_id), @stand_in.requests.sole.params
  end

  test "each call is 401 for any caller but its own, before anything else" do
    seat = @scenario.seat
    calls.each do |call|
      others = [ nil, @scenario.token_for(seat), Leverage::Tokens.issue(call[:caller].to_sym) ]
      others << (call[:caller] == "helper" ? @owner_token : @scenario.helper_token)
      others.each do |token|
        with_stand_in { send_call(call, token: token, body: { "unrelated" => true }) }

        assert_transport_error :unauthorized, "unauthenticated"
      end
    end
  end

  test "a helper token that ended answers 401" do
    @scenario.end_token(@helper)
    with_stand_in { send_call(calls.first) }

    assert_transport_error :unauthorized, "unauthenticated"
  end

  test "a missing or badly formed Idempotency-Key is 400 malformed" do
    calls.each do |call|
      [ nil, "", "has space", "a" * 129 ].each do |key|
        with_stand_in { send_call(call, key: key) }

        assert_transport_error :bad_request, "malformed"
      end
    end
  end

  test "a body that is not JSON is 400 malformed" do
    calls.select { |call| call[:body] }.each do |call|
      with_stand_in { send_call(call, raw: "{not json") }

      assert_transport_error :bad_request, "malformed"
    end
  end

  test "a body the contract refuses is 422 invalid" do
    limit = calls.first
    bad = [
      limit_body.merge("window" => "monthly"),
      limit_body.merge("task_id" => nil),
      limit_body.merge("review_id" => SecureRandom.uuid),
      limit_body.except("tool_version"),
      limit_body.merge("made_up_field" => 1)
    ]
    bad.each do |body|
      with_stand_in { send_call(limit, body: body) }

      assert_transport_error :unprocessable_content, "invalid"
    end
    out = calls.second
    [ signed_out_body.merge("task_id" => nil), signed_out_body.merge("window" => "five_hour"), signed_out_body.except("seat_id") ].each do |body|
      with_stand_in { send_call(out, body: body) }

      assert_transport_error :unprocessable_content, "invalid"
    end
  end

  test "a body on Sign in again, which takes none, is 422 invalid" do
    with_stand_in { send_call(calls.last, body: { "reason" => "because" }) }

    assert_transport_error :unprocessable_content, "invalid"
  end

  test "an id that is not a UUID names nothing: 404 not_found, after the body is checked" do
    calls.each do |call|
      with_stand_in { send_call(call, path: call[:path].sub(/[0-9a-f-]{36}/, "not-an-id")) }

      assert_transport_error :not_found, "not_found"
    end
    limit = calls.first
    with_stand_in { send_call(limit, path: limit[:path].sub(/[0-9a-f-]{36}/, "not-an-id"), body: limit_body.except("window")) }

    assert_transport_error :unprocessable_content, "invalid"
  end

  test "the same key with another body is 422 key_reused" do
    @stand_in.script("report_limit") { |_request| raise Leverage::Idempotency::KeyReused, "This key was used for another request" }
    with_stand_in { send_call(calls.first) }

    assert_response :unprocessable_content
    assert_equal "key_reused", response.parsed_body.dig("error", "code")
  end

  test "the three operations are served" do
    calls.each { |call| assert Leverage::Http::RouteTable.serves?(call[:op]), call[:op] }
  end
end
