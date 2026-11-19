require "test_helper"

# The owner's commands over HTTP (milestone 2 plan WP9, IN-9 to IN-13): one
# request per operation with Transitions::StandIn scripted to complete and
# to refuse, each request and each response held to openapi.json by
# OpenapiAssertions. A controller only signs the owner in, checks the body
# against its schema, builds a Request and renders the Outcome; what the
# entries do is proven where the entries are.
#
# params is the checked body with the path's ids added under the contract's
# own parameter names: "id" for a task, a seat or a credential, "provider"
# for a tool.
class OwnerCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  # openapi_assertions.rb leaves { and } raw in the pointer it hands to
  # json_schemer, which refuses them as a URI; encode them here (notes.md,
  # WP9, request 2).
  def escape(template) = super.gsub("{", "%7B").gsub("}", "%7D")

  Outcome = Leverage::Transitions::Outcome
  Refusal = Leverage::Transitions::Refusal

  setup do
    @scenario = Scenario.new
    @user = @scenario.owner
    @token = @scenario.owner_token
    @stand_in = Leverage::Transitions::StandIn.new
    @task_id = SecureRandom.uuid
    @seat_id = SecureRandom.uuid
    @credential_id = SecureRandom.uuid
    @helper_request_id = SecureRandom.uuid
  end

  # Each owner command the app can send in milestone 2: the operation, the
  # command it runs, the path, the body (nil for none), the params the entry
  # is given and the token-free result the scripted entry answers.
  def calls
    credential = { "credential_id" => @credential_id, "helper_request_id" => @helper_request_id }
    request = { "helper_request_id" => @helper_request_id }
    [
      { op: "add_task", command: "add_task", path: "/v1/owner/tasks",
        body: { "title" => "Fix the totals", "goal" => "Totals add up.", "priority" => "normal", "state" => "backlog" },
        result: { "task_id" => @task_id } },
      { op: "complete_contract", command: "complete_contract", path: "/v1/owner/tasks/#{@task_id}/complete-contract",
        body: { "title" => "Fix the totals", "goal" => "Totals add up.", "details" => nil,
                "criteria" => [ { "text" => "The totals add up.", "kind" => "build" }, { "text" => "A reviewer agrees.", "kind" => "review" } ], "actions" => [], "minimum_strength_rank" => nil,
                "budget_cap" => nil, "work_reference" => "~/work/invoices" },
        ids: { "id" => @task_id }, result: nil },
      { op: "cancel_task", command: "cancel", path: "/v1/owner/tasks/#{@task_id}/cancel", ids: { "id" => @task_id }, result: nil },
      { op: "allow_another_round", command: "allow_another_round", path: "/v1/owner/tasks/#{@task_id}/another-round",
        ids: { "id" => @task_id }, result: nil },
      { op: "connect_seat", command: "connect_seat", path: "/v1/owner/seats",
        body: { "name" => "Made-up agent", "role" => "builder", "provider" => "claude", "model" => nil, "effort" => nil,
                "strength_rank" => 1, "credential_id" => nil },
        result: { "seat_id" => @seat_id }, once: { "seat_token" => "made-up-value" } },
      { op: "start_seat", command: "start_seat", path: "/v1/owner/seats/#{@seat_id}/start", ids: { "id" => @seat_id }, result: request },
      { op: "stop_seat", command: "stop_seat", path: "/v1/owner/seats/#{@seat_id}/stop", ids: { "id" => @seat_id }, result: request },
      { op: "remove_seat", command: "remove_seat", path: "/v1/owner/seats/#{@seat_id}/remove", ids: { "id" => @seat_id }, result: nil },
      { op: "add_credential", command: "add_credential", path: "/v1/owner/credentials",
        body: { "credential_id" => @credential_id, "kind" => "login", "provider" => "claude", "name" => "Made-up account",
                "masked_label" => nil, "model" => nil, "effort" => nil, "strength_rank" => nil },
        result: credential },
      { op: "verify_credential", command: "verify_credential", path: "/v1/owner/credentials/#{@credential_id}/verify",
        ids: { "id" => @credential_id }, result: request },
      { op: "install_tool", command: "install_tool", path: "/v1/owner/tools/claude/install", body: { "confirmed" => true },
        ids: { "provider" => "claude" }, result: request }
    ]
  end

  def headers(key: "owner-key-1", token: @token)
    { "Authorization" => ("Bearer #{token}" if token), "Idempotency-Key" => key }.compact
  end

  # POST with the call's JSON body, or none.
  def send_call(call, key: "owner-key-1", token: @token, body: call[:body])
    if body.nil?
      post call[:path], headers: headers(key: key, token: token)
    else
      post call[:path], params: JSON.generate(body), headers: headers(key: key, token: token)
        .merge("Content-Type" => "application/json")
    end
  end

  def with_stand_in(&block) = Leverage::Transitions.with_stand_in(@stand_in, &block)

  def assert_transport_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
    assert_empty @stand_in.requests, "no command may run"
  end

  # --- every command, completed ----------------------------------------------------------------------------------

  test "each owner command runs its entry for the owner and answers the completed outcome" do
    calls.each do |call|
      stand_in = Leverage::Transitions::StandIn.new
      stand_in.script(call[:command], Outcome.completed(call[:result], once: call[:once]))
      assert_request_matches_contract("POST", call[:path], call[:body])

      Leverage::Transitions.with_stand_in(stand_in) { send_call(call, key: "key-#{call[:op]}") }

      assert_response :ok, "#{call[:op]}: #{response.body}"
      assert_response_matches_contract
      body = response.parsed_body
      assert_equal({ "key" => "key-#{call[:op]}", "command" => call[:command], "outcome" => "completed", "refusal" => nil },
        body.slice("key", "command", "outcome", "refusal"), call[:op])
      expected = call[:result] && call[:result].merge(call[:once] || {})
      if expected.nil?
        assert_nil body["result"], call[:op]
      else
        assert_equal expected, body["result"], call[:op]
      end

      request = stand_in.requests.sole
      assert_equal call[:command], request.command
      assert_equal @scenario.workspace_id, request.workspace_id
      assert_equal "owner", request.caller_kind
      assert_equal @user.id, request.caller_id
      assert_equal "key-#{call[:op]}", request.key
      assert_equal (call[:body] || {}).merge(call[:ids] || {}), request.params, call[:op]
      raw = call[:body] && JSON.generate(call[:body])
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: call[:path], body: raw.to_s), request.request_hash
    end
  end

  test "a token shown once is in the first answer only and the stored result never holds it" do
    call = calls.find { |candidate| candidate[:op] == "connect_seat" }
    @stand_in.script("connect_seat", Outcome.completed(call[:result], once: call[:once]))
    with_stand_in { send_call(call) }
    assert_equal "made-up-value", response.parsed_body.dig("result", "seat_token")

    # What the engine stores and a repeat renders: the token-free part, repeated.
    stored = Leverage::Transitions::Outcome.completed(call[:result])
    rendered = RunsCommands.outcome_body("connect_seat", "k", stored)
    assert_equal({ "seat_id" => @seat_id, "repeated" => true }, rendered[:result])
  end

  # --- every command, refused -------------------------------------------------------------------------------------

  test "each owner command answers a refusal as 409 with the refusal in the outcome" do
    calls.each do |call|
      stand_in = Leverage::Transitions::StandIn.new
      stand_in.script(call[:command], Outcome.refused(Refusal.new(code: "invalid_state")))

      Leverage::Transitions.with_stand_in(stand_in) { send_call(call, key: "refused-#{call[:op]}") }

      assert_response :conflict, call[:op]
      assert_response_matches_contract
      body = response.parsed_body
      assert_equal "refused", body["outcome"]
      assert_nil body["result"]
      assert_equal "invalid_state", body.dig("refusal", "code")
    end
  end

  test "a pending outcome is 202" do
    call = calls.find { |candidate| candidate[:op] == "cancel_task" }
    @stand_in.script("cancel", Outcome.new(outcome: :pending))
    with_stand_in { send_call(call) }
    assert_response :accepted
  end

  # --- what is checked before a command runs (IN-13) -----------------------------------------------------------

  test "every owner command answers 401 without an owner token, before anything else" do
    seat = @scenario.seat
    calls.each do |call|
      [ nil, @scenario.token_for(seat), @scenario.helper_token, Leverage::Tokens.issue(:owner) ].each do |token|
        with_stand_in { send_call(call, token: token, body: { "unrelated" => true }) }
        assert_transport_error :unauthorized, "unauthenticated"
      end
    end
  end

  test "an ended session answers 401" do
    session = @scenario.owner_session
    token = @scenario.token_for(session)
    @scenario.end_token(session)
    with_stand_in { send_call(calls.first, token: token) }
    assert_transport_error :unauthorized, "unauthenticated"
  end

  test "a missing or badly formed Idempotency-Key is 400 malformed" do
    call = calls.first
    [ nil, "", "has space", "a" * 129, "semi;colon" ].each do |key|
      with_stand_in do
        post call[:path], params: JSON.generate(call[:body]),
          headers: { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json" }
            .merge(key.nil? ? {} : { "Idempotency-Key" => key })
      end
      assert_transport_error :bad_request, "malformed"
    end
  end

  test "a body that is not JSON is 400 malformed" do
    call = calls.first
    with_stand_in do
      post call[:path], params: "{not json", headers: headers.merge("Content-Type" => "application/json")
    end
    assert_transport_error :bad_request, "malformed"
  end

  test "a body the contract refuses is 422 invalid" do
    bad = {
      "add_task" => { "goal" => "No title." },
      "complete_contract" => { "title" => "Only a title" },
      "connect_seat" => { "name" => "Made-up agent", "role" => "wizard" },
      "add_credential" => { "name" => "Made-up account" },
      "install_tool" => { "confirmed" => "yes" }
    }
    bad.each do |operation, body|
      call = calls.find { |candidate| candidate[:op] == operation }
      with_stand_in { send_call(call, body: body) }
      assert_transport_error :unprocessable_entity, "invalid"
    end
  end

  test "a body on a command that takes none is 422 invalid" do
    call = calls.find { |candidate| candidate[:op] == "cancel_task" }
    with_stand_in { send_call(call, body: { "reason" => "because" }) }
    assert_transport_error :unprocessable_entity, "invalid"
  end

  test "an id that is not a UUID names nothing: 404 not_found" do
    calls.select { |call| call[:ids]&.key?("id") }.each do |call|
      path = call[:path].sub(/[0-9a-f-]{36}/, "not-an-id")
      with_stand_in { send_call(call.merge(path: path)) }
      assert_transport_error :not_found, "not_found"
    end
  end

  test "an invalid body is 422 before a bad id is 404" do
    call = calls.find { |candidate| candidate[:op] == "complete_contract" }
    path = call[:path].sub(/[0-9a-f-]{36}/, "not-an-id")
    with_stand_in { send_call(call.merge(path: path), body: { "title" => "Only a title" }) }
    assert_transport_error :unprocessable_entity, "invalid"
  end

  test "an id the entry cannot find is the entry's 404" do
    @stand_in.script("cancel") { |_request| raise Leverage::Transitions::NotFound, "No such task" }
    call = calls.find { |candidate| candidate[:op] == "cancel_task" }
    with_stand_in { send_call(call) }
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
  end

  test "the same key with another body is 422 key_reused" do
    @stand_in.script("add_task") { |_request| raise Leverage::Idempotency::KeyReused, "This key was used for another request" }
    with_stand_in { send_call(calls.first) }
    assert_response :unprocessable_entity
    assert_equal "key_reused", response.parsed_body.dig("error", "code")
  end

  # --- GET /v1/owner/commands/{key} --------------------------------------------------------------------------

  def store_command(key:, command:, outcome: "completed", result: nil, refusal: nil, caller_id: @user.id, workspace: @scenario)
    Command.create!(workspace_id: workspace.workspace_id, caller_kind: "owner", caller_id: caller_id, key: key, command: command,
      request_hash: "a" * 64, outcome: outcome, result: result, refusal: refusal)
  end

  test "get_owner_command reads the stored outcome of an owner's key" do
    store_command(key: "stored-1", command: "add_task", result: { "task_id" => @task_id })
    store_command(key: "stored-2", command: "cancel", outcome: "refused", refusal: { "code" => "invalid_state", "rule_id" => nil, "reason" => nil })

    get "/v1/owner/commands/stored-1", headers: headers
    assert_response :ok
    assert_response_matches_contract
    assert_equal({ "key" => "stored-1", "command" => "add_task", "outcome" => "completed", "result" => { "task_id" => @task_id },
                   "refusal" => nil }, response.parsed_body)

    get "/v1/owner/commands/stored-2", headers: headers
    assert_response :ok
    assert_response_matches_contract
    assert_equal "refused", response.parsed_body["outcome"]
    assert_equal "invalid_state", response.parsed_body.dig("refusal", "code")
    assert_nil response.parsed_body["result"]
  end

  test "get_owner_command renders a token command's stored result as repeated, without a token" do
    store_command(key: "stored-3", command: "connect_seat", result: { "seat_id" => @seat_id })
    get "/v1/owner/commands/stored-3", headers: headers
    assert_response :ok
    assert_response_matches_contract
    assert_equal({ "seat_id" => @seat_id, "repeated" => true }, response.parsed_body["result"])
    assert_no_match(/token/, response.body)
  end

  test "get_owner_command is 404 for an unknown key, another caller's key and another workspace's key" do
    get "/v1/owner/commands/never-sent", headers: headers
    assert_response :not_found
    assert_matches_component("TransportError", response.parsed_body)

    store_command(key: "someone-elses", command: "cancel", caller_id: SecureRandom.uuid, workspace: @scenario)
    get "/v1/owner/commands/someone-elses", headers: headers
    assert_response :not_found

    other = Scenario.new
    store_command(key: "other-workspace", command: "cancel", caller_id: other.owner.id, workspace: other)
    get "/v1/owner/commands/other-workspace", headers: headers
    assert_response :not_found
  end

  test "get_owner_command is 401 without an owner token" do
    get "/v1/owner/commands/stored-1"
    assert_response :unauthorized
    assert_matches_component("TransportError", response.parsed_body)
  end

  test "get_owner_command takes no key and writes nothing" do
    store_command(key: "stored-4", command: "cancel")
    assert_no_difference -> { Command.count } do
      get "/v1/owner/commands/stored-4", headers: { "Authorization" => "Bearer #{@token}" }
    end
    assert_response :ok
  end
end
