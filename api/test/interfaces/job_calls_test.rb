require "test_helper"

# The agent's two job calls over HTTP (milestone 4 plan WP10, §2.3, IN-13,
# RD-34, RD-40, RD-41): claim_next_job and submit_job_result. One request
# per operation with Transitions::StandIn scripted to complete, to wait and
# to refuse, each request and each response held to openapi.json by
# OpenapiAssertions. A controller only signs the seat in, checks the body
# against its schema, builds a Request and renders the Outcome. Whether the
# seat's role may claim or hold a job is the entry's to decide and answer
# as the refusal `forbidden` (L548); what the entries do is proven where the
# entries are (WP6).
class JobCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  Kase = Struct.new(:operation, :path, :command, :body, :result, keyword_init: true) do
    # The job's id, named as the contract names it.
    def ids = path.scan(%r{/jobs/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})}).flatten.to_h { |value| [ "id", value ] }

    def params = ids.merge(body || {})
  end

  def self.example(component) = Leverage::Contract.openapi.dig("components", "schemas", component, "examples", 0)

  JOB = "00000000-0000-4000-8000-0000000000b1".freeze
  CHECK_RESULT = { "result" => { "result" => "failed", "reason" => "Made-up reason." }, "tokens" => 120, "spend" => 0.01 }.freeze
  DRAFT_RESULT = { "result" => example("CompleteContractRequest"), "tokens" => 900, "spend" => 0.05 }.freeze

  CASES = [
    Kase.new(operation: "claim_next_job", path: "/v1/jobs/claim-next", command: "claim_job", body: nil,
      result: example("ClaimJobResult")),
    Kase.new(operation: "submit_job_result", path: "/v1/jobs/#{JOB}/result", command: "submit_job_result", body: CHECK_RESULT,
      result: nil),
    Kase.new(operation: "submit_job_result", path: "/v1/jobs/#{JOB}/result", command: "submit_job_result", body: DRAFT_RESULT,
      result: {})
  ].freeze

  ROLES = %w[builder reviewer orchestrator planner].freeze

  setup do
    @scenario = Scenario.new
    @seats = ROLES.index_with { |role| @scenario.seat(role: role) }
    @orchestrator = @seats.fetch("orchestrator")
    @token = @scenario.token_for(@orchestrator)
    @stand_in = T::StandIn.new
  end

  def new_key = "key-#{SecureRandom.hex(6)}"

  def send_case(kase, key: new_key, token: @token, body: kase.body, raw: nil, path: kase.path)
    headers = {}
    headers["Authorization"] = "Bearer #{token}" if token
    headers["Idempotency-Key"] = key if key
    headers["Content-Type"] = "application/json" if body || raw
    payload = raw || (body && JSON.generate(body))
    T.with_stand_in(@stand_in) { post path, params: payload, headers: headers }
  end

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
    assert_empty @stand_in.requests, "no command may run"
  end

  CASES.each_with_index do |kase, index|
    label = "#{kase.operation} (#{kase.command}, case #{index})"

    test "#{label} answers the scripted completion with the contract's body and hands the entry its request" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      key = new_key
      assert_request_matches_contract("POST", kase.path, kase.body)
      send_case(kase, key: key)

      assert_response :ok
      assert_equal({ "key" => key, "command" => kase.command, "outcome" => "completed", "result" => kase.result, "refusal" => nil },
        response.parsed_body)
      assert_response_matches_contract

      request = @stand_in.requests.sole
      assert_equal [ kase.command, "seat", @orchestrator.id, @scenario.workspace_id, key ],
        [ request.command, request.caller_kind, request.caller_id, request.workspace_id, request.key ]
      assert_equal kase.params, request.params
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: kase.path, body: kase.body && JSON.generate(kase.body)),
        request.request_hash
    end

    test "#{label} answers a refusal as 409 with its cause, also forbidden for a seat of another role" do
      %w[forbidden invalid_state not_holder blocked_by_rule].each do |code|
        @stand_in.script(kase.command, T::Outcome.refused(T::Refusal.new(code: code)))
        send_case(kase)

        assert_response :conflict
        assert_equal "refused", response.parsed_body["outcome"]
        assert_equal code, response.parsed_body.dig("refusal", "code")
        assert_nil response.parsed_body["result"]
        assert_response_matches_contract
      end
    end

    test "#{label} reaches the entry for a seat of every role, which alone decides whether the role may" do
      @stand_in.script(kase.command, T::Outcome.refused(T::Refusal.new(code: "forbidden")))
      @seats.each do |role, seat|
        send_case(kase, token: @scenario.token_for(seat))

        assert_response :conflict, role
        assert_equal "forbidden", response.parsed_body.dig("refusal", "code"), role
        assert_equal [ "seat", seat.id ], [ @stand_in.requests.last.caller_kind, @stand_in.requests.last.caller_id ], role
      end
      assert_equal @seats.values.map(&:id), @stand_in.requests.map(&:caller_id)
    end

    test "#{label} answers a pending outcome as 202 with no result" do
      @stand_in.script(kase.command, T::Outcome.new(outcome: :pending))
      send_case(kase)

      assert_response :accepted
      assert_equal "pending", response.parsed_body["outcome"]
      assert_nil response.parsed_body["result"]
      assert_response_matches_contract
    end

    test "#{label} without an Idempotency-Key or with one of the wrong form is 400 malformed" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      [ nil, "", "has space", "a" * 129 ].each do |key|
        send_case(kase, key: key)

        assert_error :bad_request, "malformed"
      end
    end

    test "#{label} with no token, the owner's, the helper's or a removed seat's is 401 and runs nothing" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      removed = @scenario.seat(role: "orchestrator")
      @scenario.remove(removed)
      [ nil, @scenario.owner_token, @scenario.helper_token, @scenario.token_for(removed), "lvs_#{'A' * 43}" ].each do |token|
        send_case(kase, token: token)

        assert_error :unauthorized, "unauthenticated"
      end
    end

    test "#{label} answers 401 before it looks at the body or the id" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      send_case(kase, token: @scenario.owner_token, raw: "{not json", path: kase.path.sub(JOB, "not-an-id"))

      assert_error :unauthorized, "unauthenticated"
    end

    if kase.path.include?(JOB)
      test "#{label} with an id that is not a UUID is 404 and runs nothing" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        send_case(kase, path: kase.path.sub(JOB, "not-a-uuid"))

        assert_error :not_found, "not_found"
      end

      test "#{label} checks the body before the id: an invalid body for a bad id is 422" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        send_case(kase, path: kase.path.sub(JOB, "not-a-uuid"), body: kase.body.except("tokens"))

        assert_error :unprocessable_content, "invalid"
      end
    end

    if kase.body
      test "#{label} with a body that is not JSON is 400 malformed" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        send_case(kase, raw: "{not json")

        assert_error :bad_request, "malformed"
      end

      test "#{label} with a body that fails its schema is 422 invalid" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        [ kase.body.merge("made_up_field" => 1), kase.body.except("tokens"), kase.body.except("spend"), kase.body.except("result"),
          kase.body.merge("tokens" => -1), kase.body.merge("spend" => -0.5), kase.body.merge("result" => { "result" => "maybe" }),
          kase.body.merge("result" => {}), kase.body.merge("result" => "passed"), kase.body.merge("tokens" => "many") ].each do |body|
          send_case(kase, body: body)

          assert_error :unprocessable_content, "invalid"
        end
      end
    end
  end

  test "a rule check's reason is at most 500 characters (RD-31) and 500 is allowed" do
    kase = CASES.second
    @stand_in.script(kase.command, T::Outcome.completed(nil))
    long = kase.body.merge("result" => { "result" => "passed", "reason" => "x" * 501 })
    send_case(kase, body: long)

    assert_error :unprocessable_content, "invalid"

    send_case(kase, body: kase.body.merge("result" => { "result" => "passed", "reason" => "x" * 500 }))

    assert_response :ok
  end

  test "claim_next_job takes no body: an empty body and an empty object are accepted, any other is 422 invalid" do
    kase = CASES.first
    @stand_in.script(kase.command, T::Outcome.completed(kase.result))
    send_case(kase)

    assert_response :ok
    assert_equal({}, @stand_in.requests.last.params)

    send_case(kase, raw: "{}")

    assert_response :ok
    send_case(kase, raw: JSON.generate("kind" => "rule_check"))

    assert_equal "invalid", response.parsed_body.dig("error", "code")
    assert_response :unprocessable_content
    assert_equal 2, @stand_in.requests.size
  end

  test "the engine's errors become the transport errors" do
    kase = CASES.second
    { T::NotFound => [ :not_found, "not_found" ], Leverage::Idempotency::KeyReused => [ :unprocessable_content, "key_reused" ],
      T::Invalid => [ :unprocessable_content, "invalid" ] }.each do |error, (status, code)|
      @stand_in.script(kase.command) { |_request| raise error, "made up" }
      send_case(kase)

      assert_response status
      assert_equal code, response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  test "both operations are served, to the jobs controller, and write nothing themselves" do
    %w[claim_next_job submit_job_result].each do |operation|
      assert Leverage::Http::RouteTable.serves?(operation), operation
      assert_match(%r{\Av1/agent/jobs#}, Leverage::Http::RouteTable::ROUTES.fetch(operation))
    end
    @stand_in.script("claim_job", T::Outcome.completed(CASES.first.result))
    assert_no_difference [ "Command.count", "Event.count" ] do
      send_case(CASES.first)
    end
    assert_response :ok
  end
end
