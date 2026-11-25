require "test_helper"

# The five transport errors of IF-3 (400 malformed, 401 unauthenticated,
# 404 not_found, 422 key_reused, 422 invalid), each in the contract's
# TransportError body, and the outcome bodies of IF-4 that runs_commands.rb
# renders (milestone 2 plan §2.1, IN-8, IN-11, IN-13). Controllers defined
# here run commands against Leverage::Transitions::StandIn, so no entry is
# needed.
class TransportErrorsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  # Runs a command for its caller from the body the contract's add_task
  # takes, the way an owner controller does.
  class CommandController < ApplicationController
    include AuthenticatesOwner
    include RunsCommands

    def add_task
      body = Leverage::Http::RequestSchema.body!("add_task", request.raw_post)
      run_command("add_task", params: body)
    end

    def sign_in
      run_command("sign_in", hash_without: [ "password" ])
    end

    def not_found = raise(Leverage::Transitions::NotFound, "No task with that id in this workspace")
    def invalid = raise(Leverage::Transitions::Invalid, "Tasks are added to Backlog in this milestone")
  end

  setup do
    @scenario = Scenario.new
    @token = @scenario.owner_token
    @stand_in = T::StandIn.new
  end

  def with_test_routes(&block)
    with_routing do |routes|
      routes.draw do
        post "add", to: "transport_errors_test/command#add_task"
        post "sign-in", to: "transport_errors_test/command#sign_in"
        post "gone", to: "transport_errors_test/command#not_found"
        post "invalid", to: "transport_errors_test/command#invalid"
      end
      T.with_stand_in(@stand_in, &block)
    end
  end

  def headers(key: "key-1", token: @token)
    { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      .merge(key ? { "Idempotency-Key" => key } : {})
  end

  def add_body = { title: "A made-up task", details: "A made-up goal." }.to_json

  def assert_transport_error(status, code)
    assert_response status
    assert_equal "application/json", response.media_type
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
  end

  test "an unknown path is 404 not_found" do
    post "/v1/made-up", headers: headers
    assert_transport_error :not_found, "not_found"
  end

  test "a body that is not JSON is 400 malformed" do
    with_test_routes do
      post "/add", params: "{not json", headers: headers
      assert_transport_error :bad_request, "malformed"
    end
  end

  test "a missing or badly formed idempotency key is 400 malformed and runs nothing" do
    @stand_in.script("add_task", T::Outcome.completed({}))
    with_test_routes do
      post "/add", params: add_body, headers: headers(key: nil)
      assert_transport_error :bad_request, "malformed"
      post "/add", params: add_body, headers: headers(key: "has space")
      assert_transport_error :bad_request, "malformed"
      post "/add", params: add_body, headers: headers(key: "x" * 129)
      assert_transport_error :bad_request, "malformed"
    end
    assert_empty @stand_in.requests
  end

  test "a body its schema refuses is 422 invalid and runs nothing" do
    with_test_routes do
      post "/add", params: { title: "A made-up task", goal: "Obsolete field" }.to_json, headers: headers
      assert_transport_error :unprocessable_entity, "invalid"
      post "/add", params: [ 1, 2 ].to_json, headers: headers
      assert_transport_error :unprocessable_entity, "invalid"
    end
    assert_empty @stand_in.requests
  end

  # A NUL character (JSON's \u0000) fits every string schema, and
  # PostgreSQL text cannot hold one: without this check the command would
  # fail inside its transaction and answer 500, which a runner sends again
  # for ever.
  test "a NUL character anywhere in a body is 422 invalid and runs nothing" do
    bodies = [
      { title: "A made-up\u0000 task", details: "A made-up goal." },
      { title: "A made-up task", details: "A made-up goal.", criteria: [ { text: "Made-up\u0000 criterion.", kind: "build" } ] },
      { title: "A made-up task", details: "A made-up goal.", actions: [ { kind: "send", description: "\u0000" } ] }
    ]
    with_test_routes do
      bodies.each do |body|
        post "/add", params: body.to_json, headers: headers(key: "key-#{SecureRandom.hex(6)}")
        assert_transport_error :unprocessable_entity, "invalid"
        assert_equal "Text cannot contain a NUL character", response.parsed_body.dig("error", "message")
      end
    end
    assert_empty @stand_in.requests
  end

  test "RequestSchema refuses a NUL in a nested value or in a key, and not the six characters that spell its escape" do
    schema = Leverage::Http::RequestSchema
    nested = { title: "A made-up task", details: "A made-up goal.", criteria: [ { text: "a\u0000b", kind: "build" } ] }.to_json

    error = assert_raises(schema::Invalid) { schema.body!("add_task", nested) }
    assert_equal "Text cannot contain a NUL character", error.message
    assert schema.nul?({ "a" => [ { "b\u0000" => 1 } ] }), "a key"
    assert schema.nul?([ 1, nil, [ "\u0000" ] ]), "a value in a list"
    refute schema.nul?({ "a" => [ 1, 2.5, true, nil, "text", { "b" => "more text" } ] })
    spelled = schema.body!("add_task", { title: "A made-up \\u0000 task", details: "A made-up goal." }.to_json)
    assert_equal "A made-up \\u0000 task", spelled.fetch("title")
  end

  test "a missing session is 401 unauthenticated and runs nothing" do
    with_test_routes do
      post "/add", params: add_body, headers: headers(token: Leverage::Tokens.issue(:owner))
      assert_transport_error :unauthorized, "unauthenticated"
    end
    assert_empty @stand_in.requests
  end

  test "the same key with another body is 422 key_reused" do
    @stand_in.script("add_task") { raise Leverage::Idempotency::KeyReused, "This key was used for another request" }
    with_test_routes do
      post "/add", params: add_body, headers: headers
      assert_transport_error :unprocessable_entity, "key_reused"
    end
  end

  test "an entry's not found and invalid become 404 not_found and 422 invalid" do
    with_test_routes do
      post "/gone", headers: headers
      assert_transport_error :not_found, "not_found"
      post "/invalid", headers: headers
      assert_transport_error :unprocessable_entity, "invalid"
    end
  end

  test "the request handed to the transition function carries the caller, the key, the hash and the body" do
    @stand_in.script("add_task", T::Outcome.completed({ "task_id" => SecureRandom.uuid }))
    with_test_routes do
      post "/add", params: add_body, headers: headers(key: "made-up-key")
    end
    request = @stand_in.requests.sole

    assert_equal [ "add_task", @scenario.workspace_id, "owner", @scenario.owner.id, "made-up-key" ],
      [ request.command, request.workspace_id, request.caller_kind, request.caller_id, request.key ]
    assert_equal Leverage::Idempotency.request_hash(method: "POST", path: "/add", body: add_body), request.request_hash
    assert_equal({ "title" => "A made-up task", "details" => "A made-up goal." }, request.params)
  end

  test "a completed command answers 200 with the outcome body" do
    task_id = SecureRandom.uuid
    @stand_in.script("add_task", T::Outcome.completed({ "task_id" => task_id }))
    with_test_routes do
      post "/add", params: add_body, headers: headers(key: "k-200")

      assert_response :ok
      assert_equal({ "key" => "k-200", "command" => "add_task", "outcome" => "completed",
                     "result" => { "task_id" => task_id }, "refusal" => nil }, response.parsed_body)
      assert_matches_component("AddTaskCompleted", response.parsed_body)
    end
  end

  test "a refused command answers 409 with its cause" do
    @stand_in.script("add_task", T::Outcome.refused(T::Refusal.new(code: "invalid_state")))
    with_test_routes do
      post "/add", params: add_body, headers: headers(key: "k-409")

      assert_response :conflict
      assert_equal({ "key" => "k-409", "command" => "add_task", "outcome" => "refused", "result" => nil,
                     "refusal" => { "code" => "invalid_state", "rule_id" => nil, "reason" => nil } }, response.parsed_body)
      assert_matches_component("RefusedOutcome", response.parsed_body)
    end
  end

  test "a value shown once is merged into the first answer only; a repeat says repeated" do
    user_id = @scenario.owner.id
    stored = { "user_id" => user_id, "created_at" => "2026-11-19T12:00:00.000000Z" }
    answers = [ T::Outcome.completed(stored, once: { "session_token" => "lvo_#{"a" * 43}" }), T::Outcome.completed(stored) ]
    @stand_in.script("sign_in") { answers.shift }
    body = { email_address: "owner@example.test", password: "made-up-password-1" }.to_json

    with_test_routes do
      post "/sign-in", params: body, headers: headers(key: "k-once")
      assert_response :ok
      assert_equal stored.merge("session_token" => "lvo_#{"a" * 43}"), response.parsed_body.fetch("result")
      assert_matches_component("OwnerSessionCompleted", response.parsed_body)

      post "/sign-in", params: body, headers: headers(key: "k-once")
      assert_response :ok
      assert_equal stored.merge("repeated" => true), response.parsed_body.fetch("result")
      assert_matches_component("OwnerSessionCompleted", response.parsed_body)
    end
  end

  test "sign-in's request hash leaves the password out" do
    @stand_in.script("sign_in", T::Outcome.completed({}))
    with_test_routes do
      post "/sign-in", params: { email_address: "owner@example.test", password: "one" }.to_json, headers: headers(key: "a")
      post "/sign-in", params: { email_address: "owner@example.test", password: "two" }.to_json, headers: headers(key: "b")
    end

    assert_equal 1, @stand_in.requests.map(&:request_hash).uniq.size
  end

  test "a stored Connect receipt renders only the seat id" do
    stored = T::Outcome.completed({ "seat_id" => "s" })

    assert_equal({ "seat_id" => "s" }, RunsCommands.outcome_body("connect_seat", "k", stored)[:result])
    assert_equal({ "seat_id" => "s" }, RunsCommands.outcome_body("claim", "k", stored)[:result])
  end

  test "an error inside a controller still hides its message behind a 500" do
    with_routing do |routes|
      routes.draw { get "boom", to: "transport_errors_test/command#boom" }
      TransportErrorsTest::CommandController.define_method(:boom) { raise "made-up secret detail" }
      get "/boom", headers: headers

      assert_response :internal_server_error
      assert_no_match(/secret detail/, response.body)
    end
  ensure
    TransportErrorsTest::CommandController.remove_method(:boom) if TransportErrorsTest::CommandController.method_defined?(:boom)
  end

  # One rule for an operation that takes no body, the same on the agent,
  # owner and helper interfaces (RequestSchema.body!): an empty body or
  # exactly {} is accepted, and any other body is 422 invalid.
  test "an operation with no body accepts {} and refuses any other body as 422 invalid, on every interface" do
    builder = @scenario.seat(role: "builder")
    own = @scenario.seat(role: "builder", provider: "codex")
    paths = Leverage::Contract.registry.fetch("operations").to_h { |op| [ op.fetch("operation_id"), op.fetch("path") ] }
    {
      "claim_next_task" => [ @scenario.token_for(builder), {} ],
      "stop_seat" => [ @token, { "id" => own.id } ],
      "issue_seat_token" => [ @scenario.helper_token, { "id" => SecureRandom.uuid } ]
    }.each do |operation_id, (token, ids)|
      path = paths.fetch(operation_id).gsub(/\{([a-z]+)\}/) { ids.fetch(Regexp.last_match(1)) }
      post path, params: "{}", headers: headers(key: "key-#{SecureRandom.hex(6)}", token: token)
      assert_not_includes [ 400, 422 ], response.status, "#{operation_id} with {}: #{response.body}"
      post path, params: { "x" => 1 }.to_json, headers: headers(key: "key-#{SecureRandom.hex(6)}", token: token)
      assert_transport_error :unprocessable_entity, "invalid"
    end
  end

  # A body sent without the JSON media type is never parsed into params
  # (JsonBodiesOnly, lib/middleware): Rails would read it as a form, and
  # its "Parameters:" log line would print the whole body as one key, the
  # password with it (PRD, Security: no secret in a log).
  test "a body that is not sent as JSON is 400 malformed before any controller, and its password never reaches the log" do
    password = "made-up-secret-#{SecureRandom.hex(4)}"
    body = { email_address: "made-up@example.test", password: password }.to_json
    io = StringIO.new
    capture = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(capture)
    begin
      [ "application/x-www-form-urlencoded", "text/plain", nil ].each do |type|
        head = { "Idempotency-Key" => "key-#{SecureRandom.hex(6)}" }
        head["Content-Type"] = type if type
        %w[/v1/owner/session /v1/owner/setup].each do |path|
          post path, params: body, headers: head, env: (type ? {} : { "CONTENT_TYPE" => nil })
          assert_transport_error :bad_request, "malformed"
        end
      end
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
    assert_not_includes io.string, password
    assert_not_includes io.string, "made-up@example.test"
  end

  # Whatever the method and path: a doubled slash, a path without /v1 and a
  # GET with a body all reach a controller that logs its params (the
  # catch-all route or the health check), so a form body there would print
  # the password as a key too.
  test "a form body on any path or method is 400 malformed, and its password never reaches the log" do
    password = "made-up-secret-#{SecureRandom.hex(4)}"
    body = { email_address: "made-up@example.test", password: password }.to_json
    io = StringIO.new
    capture = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(capture)
    begin
      [ [ "POST", "//v1/owner/session" ], [ "POST", "/owner/session" ], [ "GET", "/v1/health" ],
        [ "PUT", "/" ] ].each do |method, path|
        env = Rack::MockRequest.env_for(path, method: method, input: body,
          "CONTENT_TYPE" => "application/x-www-form-urlencoded", "HTTP_IDEMPOTENCY_KEY" => "key-#{SecureRandom.hex(6)}")
        status, headers, answer = Rails.application.call(env)
        text = +""
        answer.each { |part| text << part }
        answer.close if answer.respond_to?(:close)
        assert_equal 400, status, "#{method} #{path}"
        assert_equal "malformed", JSON.parse(text).dig("error", "code"), "#{method} #{path}"
        assert_match %r{\Aapplication/json}, headers["content-type"]
      end
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
    assert_not_includes io.string, password
    assert_not_includes io.string, "made-up@example.test"
  end

  # A request body has a size limit (BodySizeLimit, lib/middleware): the
  # contract's length limits bound the fields that have one, and nothing
  # else bounded what the server reads into memory and parses, on the two
  # calls that need no token as on the rest. The sign-in below is valid
  # JSON that fits its schema, so without the limit it would reach the
  # controller and answer 401.
  def sign_in_body(bytes)
    body = { email_address: "made-up@example.test", password: "" }
    body[:password] = "p" * (bytes - body.to_json.bytesize)
    body.to_json
  end

  test "a body one byte over the size limit is 400 malformed before any controller; one at the limit passes" do
    limit = BodySizeLimit::LIMIT
    head = { "Content-Type" => "application/json", "Idempotency-Key" => "key-#{SecureRandom.hex(6)}" }

    post "/v1/owner/session", params: sign_in_body(limit + 1), headers: head
    assert_transport_error :bad_request, "malformed"
    assert_equal "A request body is at most #{limit} bytes", response.parsed_body.dig("error", "message")

    post "/v1/owner/session", params: sign_in_body(limit), headers: head
    assert_transport_error :unauthorized, "unauthenticated"
  end

  # The answer comes from the stated length alone, whatever the method
  # and path: the body is not read.
  class UnreadableBody
    def read(*) = raise("the body was read")
    alias_method :gets, :read
    alias_method :each, :read
    def rewind = 0
    def close = nil
  end

  def rack_call(method, path, overrides)
    env = Rack::MockRequest.env_for(path, method: method, "CONTENT_TYPE" => "application/json",
      "HTTP_HOST" => "127.0.0.1", "HTTP_IDEMPOTENCY_KEY" => "key-#{SecureRandom.hex(6)}").merge(overrides)
    env.delete("CONTENT_LENGTH") unless overrides.key?("CONTENT_LENGTH")
    status, headers, answer = Rails.application.call(env)
    text = +""
    answer.each { |part| text << part }
    answer.close if answer.respond_to?(:close)
    [ status, headers, JSON.parse(text) ]
  end

  test "a body whose stated length is over the limit is refused unread, on any path and method" do
    over = { "CONTENT_LENGTH" => (BodySizeLimit::LIMIT + 1).to_s, "rack.input" => UnreadableBody.new }
    [ [ "POST", "/v1/owner/setup" ], [ "POST", "//v1/owner/session" ], [ "POST", "/v1/tasks" ], [ "GET", "/v1/health" ],
      [ "PUT", "/" ] ].each do |method, path|
      status, headers, body = rack_call(method, path, over)

      assert_equal 400, status, "#{method} #{path}"
      assert_equal "malformed", body.dig("error", "code"), "#{method} #{path}"
      assert_matches_component("TransportError", body)
      assert_match %r{\Aapplication/json}, headers["content-type"]
    end
  end

  # Puma decodes a chunked body and states its length before the
  # application runs. A body that still arrives without one cannot be
  # measured, so it is refused and not read.
  test "a body sent in chunks with no stated length is 400 malformed and not read" do
    status, _, body = rack_call("POST", "/v1/owner/session",
      { "HTTP_TRANSFER_ENCODING" => "chunked", "rack.input" => UnreadableBody.new })

    assert_equal 400, status
    assert_equal [ "malformed", "A request body must state its length" ], body.fetch("error").values_at("code", "message")
  end

  test "the size limit leaves room for the largest body the contract's length limits allow" do
    schema = Leverage::Contract.openapi.dig("components", "schemas", "AddTaskRequest")
    text = schema.fetch("properties").values.sum { |property| property["maxLength"].to_i }
    criteria = schema.dig("properties", "criteria", "maxItems") *
      Leverage::Contract.openapi.dig("components", "schemas", "CriterionInput", "properties", "text", "maxLength")
    actions = schema.dig("properties", "actions", "maxItems") *
      Leverage::Contract.openapi.dig("components", "schemas", "ActionInput", "properties", "description", "maxLength")

    # Four bytes for a character is UTF-8's most.
    assert_operator (text + criteria + actions) * 4, :<, BodySizeLimit::LIMIT / 2
  end

  test "a GET with no body is answered whatever its media type" do
    get "/v1/health", headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    assert_response :ok
  end

  test "an empty POST with no media type still reaches its controller" do
    own = @scenario.seat(role: "builder", provider: "codex")
    post "/v1/owner/seats/#{own.id}/stop", headers: { "Authorization" => "Bearer #{@token}", "Idempotency-Key" => "key-1" }
    assert_response :conflict
    assert_equal "invalid_state", response.parsed_body.dig("refusal", "code")
  end
end
