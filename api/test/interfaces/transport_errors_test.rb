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

  def add_body = { title: "A made-up task", goal: "A made-up goal." }.to_json

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
      post "/add", params: { title: "No goal" }.to_json, headers: headers
      assert_transport_error :unprocessable_entity, "invalid"
      post "/add", params: [ 1, 2 ].to_json, headers: headers
      assert_transport_error :unprocessable_entity, "invalid"
    end
    assert_empty @stand_in.requests
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
    assert_equal({ "title" => "A made-up task", "goal" => "A made-up goal." }, request.params)
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

  test "outcome bodies give a seat the app runs a null token the first time" do
    first = T::Outcome.completed({ "seat_id" => "s" }, once: { "seat_token" => nil })
    repeat = T::Outcome.completed({ "seat_id" => "s" })

    assert_equal({ "seat_id" => "s", "seat_token" => nil }, RunsCommands.outcome_body("connect_seat", "k", first)[:result])
    assert_equal({ "seat_id" => "s", "repeated" => true }, RunsCommands.outcome_body("connect_seat", "k", repeat)[:result])
    assert_equal({ "seat_id" => "s" }, RunsCommands.outcome_body("claim", "k", repeat)[:result])
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
  # (Leverage::Http::JsonBodiesOnly): Rails would read it as a form, and
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

  test "an empty POST with no media type still reaches its controller" do
    own = @scenario.seat(role: "builder", provider: "codex")
    post "/v1/owner/seats/#{own.id}/stop", headers: { "Authorization" => "Bearer #{@token}", "Idempotency-Key" => "key-1" }
    assert_response :conflict
    assert_equal "invalid_state", response.parsed_body.dig("refusal", "code")
  end

end
