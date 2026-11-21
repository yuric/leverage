require "test_helper"

# The owner's rule, check and draft calls over HTTP (milestone 4 plan WP10,
# §2.3, IN-13): list_rules, add_rule, save_rule, enable_rule, disable_rule,
# revert_rule, remove_rule, rerun_check, override_check and draft_contract.
# One request per operation with Transitions::StandIn scripted to complete,
# to wait and to refuse, each request and each response held to openapi.json
# by OpenapiAssertions. A controller only signs the owner in, checks the
# body against its schema, builds a Request and renders the Outcome; what
# the entries do is proven where the entries are (WP6, WP8). list_rules is a
# read: its answer is Reads::Rules (WP11), whose call is replaced here by a
# spy that records what it was given.
class RuleCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  RULE = "00000000-0000-4000-8000-0000000000d1".freeze
  CHECK = "00000000-0000-4000-8000-0000000000d2".freeze
  TASK = "00000000-0000-4000-8000-0000000000d3".freeze

  def self.example(component) = Leverage::Contract.openapi.dig("components", "schemas", component, "examples", 0)

  ADD = { "name" => "Names the page", "instruction" => "The goal names the page the work changes.", "hook" => "task.before_ready",
          "scope" => { "kind" => "all_tasks", "project_ids" => [], "action_kinds" => [] } }.freeze
  SAVE = { "name" => "Names the page", "instruction" => "The goal names the page.", "parameters" => nil,
           "scope" => { "kind" => "all_tasks", "project_ids" => [], "action_kinds" => [] }, "on_fail" => "warn", "route" => nil,
           "queue_timeout_seconds" => 60, "run_timeout_seconds" => 300 }.freeze

  # The operation, the command it runs, the path, the body (nil for none),
  # the path's id (nil for none) and the result the scripted entry answers.
  Kase = Struct.new(:op, :command, :path, :body, :id, :result, keyword_init: true) do
    def params = (body || {}).merge(id ? { "id" => id } : {})
  end

  CASES = [
    Kase.new(op: "add_rule", command: "add_rule", path: "/v1/owner/rules", body: ADD, result: { "rule_id" => RULE }),
    Kase.new(op: "save_rule", command: "save_rule", path: "/v1/owner/rules/#{RULE}/versions", body: SAVE, id: RULE, result: nil),
    Kase.new(op: "enable_rule", command: "enable_rule", path: "/v1/owner/rules/#{RULE}/enable", id: RULE, result: nil),
    Kase.new(op: "disable_rule", command: "disable_rule", path: "/v1/owner/rules/#{RULE}/disable", id: RULE, result: nil),
    Kase.new(op: "revert_rule", command: "revert_rule", path: "/v1/owner/rules/#{RULE}/revert", id: RULE, result: nil),
    Kase.new(op: "remove_rule", command: "remove_rule", path: "/v1/owner/rules/#{RULE}/remove", id: RULE, result: nil),
    Kase.new(op: "rerun_check", command: "rerun_check", path: "/v1/owner/rule-checks/#{CHECK}/rerun", id: CHECK, result: nil),
    Kase.new(op: "override_check", command: "override_check", path: "/v1/owner/rule-checks/#{CHECK}/override",
      body: { "reason" => "The page is named in the details." }, id: CHECK, result: nil),
    Kase.new(op: "draft_contract", command: "draft_contract", path: "/v1/owner/tasks/#{TASK}/draft-contract", id: TASK,
      result: { "job_id" => "00000000-0000-4000-8000-0000000000d4" })
  ].freeze

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @token = @scenario.owner_token
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

  def with_rules_read(answer)
    calls = []
    original = Leverage::Reads::Rules.method(:call)
    Leverage::Reads::Rules.define_singleton_method(:call) do |*arguments|
      calls << arguments
      answer
    end
    yield calls
  ensure
    Leverage::Reads::Rules.define_singleton_method(:call, original)
  end

  CASES.each do |kase|
    label = "#{kase.op} (#{kase.command})"

    test "#{label} runs its entry for the owner and answers the completed outcome" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      key = new_key
      assert_request_matches_contract("POST", kase.path, kase.body)
      send_case(kase, key: key)

      assert_response :ok
      assert_equal({ "key" => key, "command" => kase.command, "outcome" => "completed", "result" => kase.result, "refusal" => nil },
        response.parsed_body)
      assert_response_matches_contract

      request = @stand_in.requests.sole
      assert_equal [ kase.command, "owner", @owner.id, @scenario.workspace_id, key ],
        [ request.command, request.caller_kind, request.caller_id, request.workspace_id, request.key ]
      assert_equal kase.params, request.params
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: kase.path, body: kase.body ? JSON.generate(kase.body) : ""),
        request.request_hash
    end

    test "#{label} answers a refusal as 409 and a waiting command as 202" do
      @stand_in.script(kase.command, T::Outcome.refused(T::Refusal.new(code: "invalid_state")))
      send_case(kase)

      assert_response :conflict
      assert_equal "refused", response.parsed_body["outcome"]
      assert_equal "invalid_state", response.parsed_body.dig("refusal", "code")
      assert_nil response.parsed_body["result"]
      assert_response_matches_contract

      @stand_in.script(kase.command, T::Outcome.new(outcome: :pending))
      send_case(kase)

      assert_response :accepted
      assert_nil response.parsed_body["result"]
      assert_response_matches_contract
    end

    test "#{label} with a missing or badly formed Idempotency-Key is 400 malformed" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      [ nil, "", "has space", "a" * 129 ].each do |key|
        send_case(kase, key: key)

        assert_error :bad_request, "malformed"
      end
    end

    test "#{label} with no token, a seat's, the helper's or an ended session's is 401, before the body or the id" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      session = @scenario.owner_session
      ended = @scenario.token_for(session)
      @scenario.end_token(session)
      [ nil, @scenario.token_for(@scenario.seat(role: "orchestrator")), @scenario.helper_token, ended, "lvo_#{'A' * 43}" ].each do |token|
        send_case(kase, token: token, raw: "{not json", path: kase.path.sub(/[0-9a-f-]{36}/, "not-an-id"))

        assert_error :unauthorized, "unauthenticated"
      end
    end

    if kase.id
      test "#{label} with an id that is not a UUID is 404 and runs nothing" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        send_case(kase, path: kase.path.sub(/[0-9a-f-]{36}/, "not-an-id"))

        assert_error :not_found, "not_found"
      end

      test "#{label} answers the entry's 404 for an id that names nothing in the workspace" do
        @stand_in.script(kase.command) { |_request| raise T::NotFound, "No such #{kase.op}" }
        send_case(kase)

        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
        assert_matches_component("TransportError", response.parsed_body)
      end
    end

    if kase.body
      test "#{label} with a body that is not JSON is 400 malformed" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        send_case(kase, raw: "{not json")

        assert_error :bad_request, "malformed"
      end

      test "#{label} with a body that fails its schema is 422 invalid, before a bad id is 404" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        [ kase.body.merge("made_up_field" => 1), kase.body.except(kase.body.keys.first), {}, kase.body.merge(kase.body.keys.first => 7) ]
          .each do |body|
          send_case(kase, body: body, path: kase.path.sub(/[0-9a-f-]{36}/, "not-an-id"))

          assert_error :unprocessable_content, "invalid"
        end
      end
    else
      test "#{label} takes no body: an empty body and an empty object are accepted, any other is 422 invalid" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        send_case(kase)

        assert_response :ok
        send_case(kase, raw: "{}")

        assert_response :ok
        assert_equal [ kase.params, kase.params ], @stand_in.requests.map(&:params)
        send_case(kase, raw: JSON.generate("reason" => "because"))

        assert_response :unprocessable_content
        assert_equal "invalid", response.parsed_body.dig("error", "code")
        assert_equal 2, @stand_in.requests.size
      end
    end
  end

  test "add_rule refuses a hook that is not one of the five and a scope with no kind" do
    kase = CASES.first
    @stand_in.script(kase.command, T::Outcome.completed(kase.result))
    [ ADD.merge("hook" => "task.before_everything"), ADD.merge("hook" => "review.assign"), ADD.merge("name" => ""),
      ADD.merge("instruction" => ""), ADD.merge("scope" => {}), ADD.except("scope") ].each do |body|
      send_case(kase, body: body)

      assert_error :unprocessable_content, "invalid"
    end
  end

  test "save_rule refuses a route or on_fail value outside the contract's lists and a timeout below one" do
    kase = CASES.second
    @stand_in.script(kase.command, T::Outcome.completed(kase.result))
    [ SAVE.merge("route" => "planner"), SAVE.merge("on_fail" => "ignore"), SAVE.merge("queue_timeout_seconds" => 0),
      SAVE.merge("run_timeout_seconds" => 0), SAVE.except("parameters") ].each do |body|
      send_case(kase, body: body)

      assert_error :unprocessable_content, "invalid"
    end
    send_case(kase, body: SAVE.merge("route" => "orchestrator", "on_fail" => "block", "parameters" => { "minimum_count" => 2 }))

    assert_response :ok
  end

  test "override_check needs a reason that is not empty" do
    kase = CASES.find { |candidate| candidate.op == "override_check" }
    @stand_in.script(kase.command, T::Outcome.completed(nil))
    [ { "reason" => "" }, {} ].each do |body|
      send_case(kase, body: body)

      assert_error :unprocessable_content, "invalid"
    end
  end

  test "the engine's key_reused becomes 422 key_reused" do
    @stand_in.script("add_rule") { |_request| raise Leverage::Idempotency::KeyReused, "This key was used for another request" }
    send_case(CASES.first)

    assert_response :unprocessable_content
    assert_equal "key_reused", response.parsed_body.dig("error", "code")
  end

  test "the same key sent again with the same body reaches the engine's repeat, not the controller's" do
    @stand_in.script("remove_rule", T::Outcome.completed(nil))
    kase = CASES.find { |candidate| candidate.op == "remove_rule" }
    2.times { send_case(kase, key: "repeat-key") }

    assert_equal [ "repeat-key", "repeat-key" ], @stand_in.requests.map(&:key)
    assert_equal 1, @stand_in.requests.map(&:request_hash).uniq.size
  end

  # list_rules

  test "list_rules answers the read for the owner's workspace, held to the contract" do
    answer = self.class.example("RulesList")
    with_rules_read(answer) do |calls|
      get "/v1/owner/rules", headers: { "Authorization" => "Bearer #{@token}" }

      assert_response :ok
      assert_equal [ [ @scenario.workspace_id ] ], calls
    end
    assert_equal answer, response.parsed_body
    assert_response_matches_contract
  end

  test "list_rules answers the stubbed first version too, and takes no key and writes nothing" do
    assert_no_difference [ "Command.count", "Event.count" ] do
      get "/v1/owner/rules", headers: { "Authorization" => "Bearer #{@token}" }
    end
    assert_response :ok
    assert_response_matches_contract
  end

  test "list_rules answers the seven shipped rules as install_shipped_rules writes them, held to the contract" do
    install = Leverage::Timers.apply_workspace(@scenario.workspace, "install_shipped_rules", at: @scenario.database_now)
    assert install.completed?, install.inspect

    get "/v1/owner/rules", headers: { "Authorization" => "Bearer #{@token}" }

    assert_response :ok
    assert_response_matches_contract
    rules = response.parsed_body.fetch("rules").index_by { |item| item.dig("rule", "key") }
    assert_equal Leverage::Rules::Shipped.all.map(&:key), rules.keys
    approvals = rules.fetch("orchestrator_approves_actions")
    assert_equal [ "model", nil, true ], [ approvals.dig("version", "checker"), approvals["sentence"], approvals["acts"] ]
    assert Leverage::Rules::Shipped.find("orchestrator_approves_actions").instruction == approvals.dig("version", "instruction")
    assert_kind_of String, rules.fetch("specific_details").dig("version", "instruction")
    rules.each_value do |item|
      instruction = item.dig("version", "instruction")
      assert(instruction.nil? || instruction.is_a?(String), item.dig("rule", "key"))
    end
  end

  test "list_rules is 401 for no token, a seat's, the helper's and an ended session's" do
    session = @scenario.owner_session
    ended = @scenario.token_for(session)
    @scenario.end_token(session)
    with_rules_read(self.class.example("RulesList")) do |calls|
      [ nil, @scenario.token_for(@scenario.seat(role: "orchestrator")), @scenario.helper_token, ended ].each do |token|
        get "/v1/owner/rules", headers: ({ "Authorization" => "Bearer #{token}" } if token).to_h

        assert_response :unauthorized
        assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
        assert_matches_component("TransportError", response.parsed_body)
      end
      assert_empty calls
    end
  end

  test "the ten operations are served, each to its controller" do
    { "list_rules" => "v1/owner/rules#index", "add_rule" => "v1/owner/rules#create", "save_rule" => "v1/owner/rules#versions",
      "enable_rule" => "v1/owner/rules#enable", "disable_rule" => "v1/owner/rules#disable", "revert_rule" => "v1/owner/rules#revert",
      "remove_rule" => "v1/owner/rules#remove", "rerun_check" => "v1/owner/rule_checks#rerun",
      "override_check" => "v1/owner/rule_checks#override", "draft_contract" => "v1/owner/tasks#draft_contract" }.each do |operation, target|
      assert Leverage::Http::RouteTable.serves?(operation), operation
      assert_equal target, Leverage::Http::RouteTable::ROUTES.fetch(operation)
    end
  end
end
