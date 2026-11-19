require "test_helper"

# The helper's HTTP calls GET /v1/helper/next, report_request_progress and
# report_request_result (milestone 2 plan WP8, IF-15, IN-10, EN-20). The
# two reports run against Transitions::StandIn; get_helper_next reads the
# real rows. seat-token and the run reports are WP6's. Every request and
# response is held to openapi.json by OpenapiAssertions.
class HelperCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  # OpenapiAssertions#escape leaves the braces of a path template in the
  # JSON pointer, which is not a URI; percent-encode them (reported to the
  # managing agent in notes.md, WP8: the support file is WP1's).
  def escape(template) = super.gsub("{", "%7B").gsub("}", "%7D")

  T = Leverage::Transitions

  REQUEST = "00000000-0000-4000-8000-0000000000b1".freeze
  PROGRESS = { "check" => "signed_in", "state" => "waiting_for_sign_in", "failure" => nil, "install" => nil }.freeze
  RESULT = { "result" => { "outcome" => "finished", "tool_version" => "9.9.9-made-up", "plan" => nil, "account_email" => nil,
                           "checks" => [ { "check" => "tool_installed", "passed" => true, "failure" => nil } ] } }.freeze

  setup do
    @scenario = Scenario.new
    @helper = @scenario.helper
    @token = @scenario.helper_token
    @stand_in = T::StandIn.new
  end

  def new_key = "key-#{SecureRandom.hex(6)}"

  def post_as(path, body, key: new_key, token: @token, raw: nil)
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{token}" if token
    headers["Idempotency-Key"] = key if key
    T.with_stand_in(@stand_in) { post path, params: raw || JSON.generate(body), headers: headers }
  end

  def get_as(path, token: @token)
    headers = {}
    headers["Authorization"] = "Bearer #{token}" if token
    get path, headers: headers
  end

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
  end

  def queue(kind = "run_add_checks", scenario: @scenario, requested_at: nil, **columns)
    HelperRequest.create!(workspace_id: scenario.workspace_id, kind: kind, state: "queued",
      requested_at: requested_at || scenario.database_now, **columns)
  end

  { "report_request_progress" => [ "progress", PROGRESS ], "report_request_result" => [ "result", RESULT ] }.each do |command, (segment, body)|
    path = "/v1/helper/requests/#{REQUEST}/#{segment}"

    test "#{command} answers the scripted completion and hands the entry the helper's request" do
      @stand_in.script(command, T::Outcome.completed({}))
      key = new_key
      assert_request_matches_contract("POST", path, body)
      post_as path, body, key: key

      assert_response :ok
      assert_equal({ "key" => key, "command" => command, "outcome" => "completed", "result" => {}, "refusal" => nil },
        response.parsed_body)
      assert_response_matches_contract

      request = @stand_in.requests.sole
      assert_equal [ command, "helper", @helper.id, @scenario.workspace_id, key ],
        [ request.command, request.caller_kind, request.caller_id, request.workspace_id, request.key ]
      assert_equal({ "id" => REQUEST }.merge(body), request.params)
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: path, body: JSON.generate(body)), request.request_hash
    end

    test "#{command} answers the scripted refusal with 409" do
      @stand_in.script(command, T::Outcome.refused(T::Refusal.new(code: "invalid_state")))
      post_as path, body

      assert_response :conflict
      assert_equal({ "code" => "invalid_state", "rule_id" => nil, "reason" => nil }, response.parsed_body["refusal"])
      assert_response_matches_contract
    end

    test "#{command} without a key, with a body that fails its schema, with a bad id and with a seat's token is refused first" do
      @stand_in.script(command, T::Outcome.completed({}))
      post_as path, body, key: nil

      assert_error :bad_request, "malformed"
      post_as path, body, raw: "{not json"

      assert_error :bad_request, "malformed"
      post_as path, body.merge("made_up_field" => 1)

      assert_error :unprocessable_content, "invalid"
      post_as "/v1/helper/requests/not-a-uuid/#{segment}", body

      assert_error :not_found, "not_found"
      [ nil, @scenario.token_for(@scenario.seat(role: "builder")), @scenario.owner_token ].each do |token|
        post_as path, body, token: token

        assert_error :unauthorized, "unauthenticated"
      end
      assert_empty @stand_in.requests
    end

    test "#{command} with an ended helper token is 401" do
      @scenario.end_token(@helper)
      post_as path, body

      assert_error :unauthorized, "unauthenticated"
    end
  end

  # get_helper_next

  test "get_helper_next answers the oldest queued request as picked up, and the next call the next request" do
    seat = @scenario.seat(role: "builder", credential: @scenario.credential)
    older = queue("start_seat", seat_id: seat.id, params: { "role" => "builder", "provider" => "claude" },
      requested_at: @scenario.database_now - 60)
    newer = queue("run_add_checks", params: { "provider" => "claude", "credential_kind" => "login" })

    get_as "/v1/helper/next?wait=0"

    assert_response :ok
    assert_response_matches_contract
    body = response.parsed_body["request"]
    assert_equal [ older.id, "start_seat", seat.id, "picked_up", { "role" => "builder", "provider" => "claude" }, [], nil ],
      body.values_at("id", "kind", "seat_id", "state", "params", "progress", "result")
    assert_not_nil body["picked_up_at"]
    assert_nil body["finished_at"]
    assert_equal "picked_up", older.reload.state
    assert_not_nil older.picked_up_at

    get_as "/v1/helper/next?wait=0"

    assert_equal newer.id, response.parsed_body.dig("request", "id")
    assert_response_matches_contract

    get_as "/v1/helper/next?wait=0"

    assert_equal({ "request" => nil }, response.parsed_body)
    assert_response_matches_contract
  end

  test "get_helper_next does not answer another workspace's request, nor one that is not queued" do
    queue("verify", scenario: Scenario.new)
    HelperRequest.create!(workspace_id: @scenario.workspace_id, kind: "verify", state: "finished", requested_at: @scenario.database_now,
      picked_up_at: @scenario.database_now, finished_at: @scenario.database_now, result: { "outcome" => "finished", "checks" => [] })
    HelperRequest.create!(workspace_id: @scenario.workspace_id, kind: "verify", state: "picked_up", requested_at: @scenario.database_now,
      picked_up_at: @scenario.database_now)

    get_as "/v1/helper/next?wait=0"

    assert_equal({ "request" => nil }, response.parsed_body)
  end

  test "get_helper_next renders a request's progress and times as the contract has them" do
    request = queue("run_add_checks", params: { "provider" => "claude", "credential_kind" => "login" },
      progress: [ { "check" => "tool_installed", "state" => "passed", "failure" => nil, "install" => nil } ])

    get_as "/v1/helper/next?wait=0"

    body = response.parsed_body["request"]
    assert_response_matches_contract
    assert_equal request.progress, body["progress"]
    assert_equal request.reload.updated_at.utc.iso8601(6), body["updated_at"]
    assert_equal request.requested_at.utc.iso8601(6), body["requested_at"]
  end

  test "get_helper_next takes a wait of 0 to 30 whole seconds and nothing else" do
    [ "wait=31", "wait=-1", "wait=abc", "wait=1.5", "wait=" ].each do |query|
      get_as "/v1/helper/next?#{query}"

      assert_error :bad_request, "malformed"
    end
  end

  test "get_helper_next is 401 with no token, a seat's token or an owner's token" do
    [ nil, @scenario.token_for(@scenario.seat(role: "builder")), @scenario.owner_token ].each do |token|
      get_as "/v1/helper/next?wait=0", token: token

      assert_error :unauthorized, "unauthenticated"
    end
  end

  test "get_helper_next records the helper's last report at most every 15 seconds, and picks nothing up on a 401" do
    queued = queue("verify")
    assert_nil @helper.reload.last_reported_at

    get_as "/v1/helper/next?wait=0"

    first = @helper.reload.last_reported_at
    assert_in_delta @scenario.database_now.to_f, first.to_f, 5

    @helper.update_columns(last_reported_at: @scenario.database_now - 10)
    stale = @helper.reload.last_reported_at
    get_as "/v1/helper/next?wait=0"

    assert_equal stale, @helper.reload.last_reported_at

    @helper.update_columns(last_reported_at: @scenario.database_now - 16)
    get_as "/v1/helper/next?wait=0"

    assert_operator @helper.reload.last_reported_at, :>, @scenario.database_now - 5

    get_as "/v1/helper/next?wait=0", token: "lvh_#{'A' * 43}"

    assert_response :unauthorized
    assert_equal "picked_up", queued.reload.state
  end

  test "get_helper_next writes no event and no commands row" do
    queue("verify")
    before = [ Event.count, Command.count ]

    get_as "/v1/helper/next?wait=0"

    assert_equal before, [ Event.count, Command.count ]
  end
end
