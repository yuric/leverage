require "test_helper"

# The owner's controls over HTTP (milestone 3 plan WP7, §2.3, HE-24, HE-25,
# HE-27): promote_task, edit_contract, hold_task, resume_task, pause_seat,
# resume_seat and change_seat. One request per operation with
# Transitions::StandIn scripted to complete and to refuse, each request and
# each response held to openapi.json by OpenapiAssertions. A controller only
# signs the owner in, checks the body against its schema (400 malformed, 422
# invalid), then its path id (404), builds a Request and renders the
# Outcome; what the entries do is proven where the entries are. params is
# the checked body with the path's id under "id".
class OwnerControlsCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @token = @scenario.owner_token
    @stand_in = T::StandIn.new
    @task_id = SecureRandom.uuid
    @seat_id = SecureRandom.uuid
  end

  def contract_body
    { "title" => "Fix the totals", "goal" => "Totals add up.", "details" => nil,
      "criteria" => [ { "text" => "The totals add up.", "kind" => "build" }, { "text" => "A reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => "~/work/invoices" }
  end

  def calls
    [
      { op: "promote_task", command: "promote", path: "/v1/owner/tasks/#{@task_id}/promote", ids: { "id" => @task_id } },
      { op: "edit_contract", command: "edit_contract", path: "/v1/owner/tasks/#{@task_id}/contract", body: contract_body,
        ids: { "id" => @task_id } },
      { op: "hold_task", command: "hold", path: "/v1/owner/tasks/#{@task_id}/hold", ids: { "id" => @task_id } },
      { op: "resume_task", command: "resume", path: "/v1/owner/tasks/#{@task_id}/resume", ids: { "id" => @task_id } },
      { op: "pause_seat", command: "pause_seat", path: "/v1/owner/seats/#{@seat_id}/pause", ids: { "id" => @seat_id } },
      { op: "resume_seat", command: "resume_seat", path: "/v1/owner/seats/#{@seat_id}/resume", ids: { "id" => @seat_id } },
      { op: "change_seat", command: "change_seat", path: "/v1/owner/seats/#{@seat_id}/change",
        body: { "name" => "Made-up agent", "model" => nil, "effort" => "high", "strength_rank" => 2, "enabled" => false },
        ids: { "id" => @seat_id } }
    ]
  end

  def headers(key: "control-key-1", token: @token)
    { "Authorization" => ("Bearer #{token}" if token), "Idempotency-Key" => key }.compact
  end

  def send_call(call, key: "control-key-1", token: @token, body: call[:body], raw: nil, path: call[:path])
    payload = raw || (body && JSON.generate(body))
    if payload.nil?
      post path, headers: headers(key: key, token: token)
    else
      post path, params: payload, headers: headers(key: key, token: token).merge("Content-Type" => "application/json")
    end
  end

  def with_stand_in(&block) = T.with_stand_in(@stand_in, &block)

  def assert_transport_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
    assert_empty @stand_in.requests, "no command may run"
  end

  test "each control runs its entry for the owner and answers the completed outcome" do
    calls.each do |call|
      stand_in = T::StandIn.new
      stand_in.script(call[:command], T::Outcome.completed(nil))
      assert_request_matches_contract("POST", call[:path], call[:body])

      T.with_stand_in(stand_in) { send_call(call, key: "key-#{call[:op]}") }

      assert_response :ok, "#{call[:op]}: #{response.body}"
      assert_response_matches_contract
      body = response.parsed_body
      assert_equal({ "key" => "key-#{call[:op]}", "command" => call[:command], "outcome" => "completed", "result" => nil,
                     "refusal" => nil }, body.slice("key", "command", "outcome", "result", "refusal"), call[:op])

      request = stand_in.requests.sole
      assert_equal [ call[:command], @scenario.workspace_id, "owner", @owner.id, "key-#{call[:op]}" ],
        [ request.command, request.workspace_id, request.caller_kind, request.caller_id, request.key ]
      assert_equal (call[:body] || {}).merge(call[:ids]), request.params, call[:op]
      raw = call[:body] && JSON.generate(call[:body])
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: call[:path], body: raw.to_s), request.request_hash
    end
  end

  test "each control answers a refusal as 409 with the refusal in the outcome" do
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
    @stand_in.script("hold", T::Outcome.new(outcome: :pending))
    with_stand_in { send_call(calls.find { |call| call[:op] == "hold_task" }) }

    assert_response :accepted
  end

  test "every control is 401 without an owner token, before anything else" do
    seat = @scenario.seat
    calls.each do |call|
      [ nil, @scenario.token_for(seat), @scenario.helper_token, Leverage::Tokens.issue(:owner) ].each do |token|
        with_stand_in { send_call(call, token: token, body: { "unrelated" => true }) }

        assert_transport_error :unauthorized, "unauthenticated"
      end
    end
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
    bad = {
      "edit_contract" => { "title" => "Only a title" },
      "change_seat" => { "role" => "wizard" }
    }
    bad.each do |operation, body|
      with_stand_in { send_call(calls.find { |call| call[:op] == operation }, body: body) }

      assert_transport_error :unprocessable_content, "invalid"
    end
    change = calls.find { |call| call[:op] == "change_seat" }
    [ { "name" => "" }, { "strength_rank" => -1 }, { "enabled" => "yes" }, { "made_up_field" => 1 } ].each do |body|
      with_stand_in { send_call(change, body: body) }

      assert_transport_error :unprocessable_content, "invalid"
    end
  end

  test "a change with nothing to change is a valid body" do
    change = calls.find { |call| call[:op] == "change_seat" }
    @stand_in.script("change_seat", T::Outcome.completed(nil))
    with_stand_in { send_call(change, body: {}) }

    assert_response :ok
    assert_equal({ "id" => @seat_id }, @stand_in.requests.sole.params)
  end

  test "a body on a control that takes none is 422 invalid" do
    calls.reject { |call| call[:body] }.each do |call|
      with_stand_in { send_call(call, body: { "reason" => "because" }) }

      assert_transport_error :unprocessable_content, "invalid"
    end
  end

  test "an id that is not a UUID names nothing: 404 not_found, and an invalid body is 422 before it" do
    calls.each do |call|
      with_stand_in { send_call(call, path: call[:path].sub(/[0-9a-f-]{36}/, "not-an-id")) }

      assert_transport_error :not_found, "not_found"
    end
    edit = calls.find { |call| call[:op] == "edit_contract" }
    with_stand_in { send_call(edit, path: edit[:path].sub(/[0-9a-f-]{36}/, "not-an-id"), body: { "title" => "Only a title" }) }

    assert_transport_error :unprocessable_content, "invalid"
  end

  test "an id the entry cannot find is the entry's 404" do
    @stand_in.script("pause_seat") { |_request| raise T::NotFound, "No such seat" }
    with_stand_in { send_call(calls.find { |call| call[:op] == "pause_seat" }) }

    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
  end

  test "the same key with another body is 422 key_reused" do
    @stand_in.script("change_seat") { |_request| raise Leverage::Idempotency::KeyReused, "This key was used for another request" }
    with_stand_in { send_call(calls.last) }

    assert_response :unprocessable_content
    assert_equal "key_reused", response.parsed_body.dig("error", "code")
  end

  test "the seven operations are served, each to a v1/owner controller" do
    calls.each do |call|
      assert Leverage::Http::RouteTable.serves?(call[:op]), call[:op]
      assert_match(%r{\Av1/owner/}, Leverage::Http::RouteTable::ROUTES.fetch(call[:op]))
    end
  end
end
