require "test_helper"

# The agent's HTTP calls other than GET /v1/next (milestone 2 plan WP8, §2.1
# Controllers and reads, IN-13): one request per operation, with
# Transitions::StandIn scripted to complete and to refuse, each request and
# each response held to openapi.json by OpenapiAssertions. The controllers
# only sign the seat in, check the body, build a Request and render; what a
# command does is the entries' and has its own tests.
class AgentCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  T = Leverage::Transitions

  Kase = Struct.new(:operation, :verb, :path, :command, :body, :result, keyword_init: true) do
    # The ids of the path, named as the contract names them.
    def ids
      path.scan(%r{/(?:tasks|reviews|criteria)/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})}).flatten.zip(%w[id cid]).to_h { |value, name| [ name, value ] }
    end

    def params = ids.merge(body || {})
  end

  def self.example(component) = Leverage::Contract.openapi.dig("components", "schemas", component, "examples", 0)

  TASK = "00000000-0000-4000-8000-0000000000a1".freeze
  CRITERION = "00000000-0000-4000-8000-0000000000a2".freeze
  REVIEW = "00000000-0000-4000-8000-0000000000a3".freeze
  EVIDENCE = { "evidence" => { "kind" => "link", "value" => "https://example.test/made-up" } }.freeze
  PASSED = { "verdict" => "passed", "failed_criteria" => [], "notes" => "Made-up notes.", "tokens" => 0, "spend" => 0 }.freeze
  FAILED = { "verdict" => "failed", "failed_criteria" => [ CRITERION ], "notes" => "Made-up notes.", "tokens" => 12, "spend" => 0 }.freeze
  ACK = { "briefing_hash" => "made-up-hash" }.freeze

  CASES = [
    Kase.new(operation: "claim_next_task", verb: :post, path: "/v1/tasks/claim-next", command: "claim", body: nil,
      result: example("ClaimTaskResult")),
    Kase.new(operation: "acknowledge_task_briefing", verb: :post, path: "/v1/tasks/#{TASK}/ack-briefing",
      command: "acknowledge_briefing", body: ACK, result: {}),
    Kase.new(operation: "heartbeat_task", verb: :post, path: "/v1/tasks/#{TASK}/heartbeat", command: "heartbeat", body: nil,
      result: example("HeartbeatResult")),
    Kase.new(operation: "start_criterion", verb: :post, path: "/v1/tasks/#{TASK}/criteria/#{CRITERION}/start",
      command: "start_criterion", body: nil, result: {}),
    Kase.new(operation: "pass_criterion", verb: :post, path: "/v1/tasks/#{TASK}/criteria/#{CRITERION}/pass",
      command: "pass_criterion", body: EVIDENCE, result: {}),
    Kase.new(operation: "submit_task", verb: :post, path: "/v1/tasks/#{TASK}/submit", command: "submit",
      body: { "handoff_note" => "Made-up note.", "work_reference" => "~/work/made-up" }, result: {}),
    Kase.new(operation: "release_task", verb: :post, path: "/v1/tasks/#{TASK}/release", command: "release",
      body: { "reason" => "unable_to_continue" }, result: {}),
    Kase.new(operation: "claim_next_review", verb: :post, path: "/v1/reviews/claim-next", command: "claim_review", body: nil,
      result: example("ClaimReviewResult")),
    Kase.new(operation: "heartbeat_review", verb: :post, path: "/v1/reviews/#{REVIEW}/heartbeat", command: "heartbeat_review",
      body: nil, result: example("HeartbeatResult")),
    Kase.new(operation: "release_review", verb: :post, path: "/v1/reviews/#{REVIEW}/release", command: "release_review",
      body: nil, result: {}),
    Kase.new(operation: "acknowledge_review_briefing", verb: :post, path: "/v1/reviews/#{REVIEW}/ack-briefing",
      command: "acknowledge_review_briefing", body: ACK, result: {}),
    Kase.new(operation: "give_verdict", verb: :post, path: "/v1/reviews/#{REVIEW}/verdict", command: "pass_review",
      body: PASSED, result: {}),
    Kase.new(operation: "give_verdict", verb: :post, path: "/v1/reviews/#{REVIEW}/verdict", command: "fail_review",
      body: FAILED, result: {})
  ].freeze

  # The agent calls that only read.
  READS = [
    [ "get_next", "/v1/next?wait=0" ],
    [ "get_command", "/v1/commands/made-up-key" ],
    [ "get_task_briefing", "/v1/tasks/#{TASK}/briefing" ],
    [ "get_review_briefing", "/v1/reviews/#{REVIEW}/briefing" ]
  ].freeze

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @token = @scenario.token_for(@builder)
    @stand_in = T::StandIn.new
  end

  def new_key = "key-#{SecureRandom.hex(6)}"

  def send_case(kase, key: new_key, token: @token, body: kase.body, raw: nil)
    headers = {}
    headers["Authorization"] = "Bearer #{token}" if token
    headers["Idempotency-Key"] = key if key
    headers["Content-Type"] = "application/json" if body || raw
    payload = raw || (body && JSON.generate(body))
    T.with_stand_in(@stand_in) { process kase.verb, kase.path, params: payload, headers: headers }
  end

  def get_as(path, token: @token)
    headers = {}
    headers["Authorization"] = "Bearer #{token}" if token
    T.with_stand_in(@stand_in) { get path, headers: headers }
  end

  def assert_error(status, code)
    assert_response status
    assert_equal code, response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
  end

  CASES.each do |kase|
    label = "#{kase.operation} (#{kase.command})"

    test "#{label} answers the scripted completion with the contract's body and hands the entry its request" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      key = new_key
      assert_request_matches_contract(kase.verb.to_s.upcase, kase.path, kase.body)
      send_case(kase, key: key)

      assert_response :ok
      assert_equal({ "key" => key, "command" => kase.command, "outcome" => "completed", "result" => kase.result, "refusal" => nil },
        response.parsed_body)
      assert_response_matches_contract

      request = @stand_in.requests.sole
      assert_equal [ kase.command, "seat", @builder.id, @scenario.workspace_id, key ],
        [ request.command, request.caller_kind, request.caller_id, request.workspace_id, request.key ]
      assert_equal kase.params, request.params
      assert_equal Leverage::Idempotency.request_hash(method: "POST", path: kase.path, body: kase.body && JSON.generate(kase.body)),
        request.request_hash
    end

    test "#{label} answers the scripted refusal with 409 and the refusal's cause" do
      @stand_in.script(kase.command, T::Outcome.refused(T::Refusal.new(code: "not_holder")))
      send_case(kase)

      assert_response :conflict
      assert_equal "refused", response.parsed_body["outcome"]
      assert_equal({ "code" => "not_holder", "rule_id" => nil, "reason" => nil }, response.parsed_body["refusal"])
      assert_nil response.parsed_body["result"]
      assert_response_matches_contract
    end

    test "#{label} without an Idempotency-Key is 400 malformed and runs nothing" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      send_case(kase, key: nil)

      assert_error :bad_request, "malformed"
      assert_empty @stand_in.requests
    end

    test "#{label} with an Idempotency-Key of the wrong form is 400 malformed" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      send_case(kase, key: "not a key!")

      assert_error :bad_request, "malformed"
      assert_empty @stand_in.requests
    end

    test "#{label} with no token, an owner's token or a removed seat's token is 401 and runs nothing" do
      @stand_in.script(kase.command, T::Outcome.completed(kase.result))
      removed = @scenario.seat(role: "builder")
      @scenario.remove(removed)
      [ nil, @scenario.owner_token, @scenario.token_for(removed), "lvs_#{'A' * 43}" ].each do |token|
        send_case(kase, token: token)

        assert_error :unauthorized, "unauthenticated"
      end
      assert_empty @stand_in.requests
    end

    if kase.path.match?(/#{TASK}|#{REVIEW}/)
      test "#{label} with an id that is not a UUID is 404 and runs nothing" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        bad = kase.dup
        bad.path = kase.path.sub(/#{TASK}|#{REVIEW}/, "not-a-uuid")
        send_case(bad)

        assert_error :not_found, "not_found"
        assert_empty @stand_in.requests
      end
    end

    if kase.body
      test "#{label} with a body that is not JSON is 400 malformed and with a body that fails its schema is 422 invalid" do
        @stand_in.script(kase.command, T::Outcome.completed(kase.result))
        send_case(kase, raw: "{not json")

        assert_error :bad_request, "malformed"

        send_case(kase, body: kase.body.merge("made_up_field" => 1))

        assert_error :unprocessable_content, "invalid"
        assert_empty @stand_in.requests
      end
    end
  end

  test "give_verdict runs pass_review for a passed verdict and fail_review for a failed one" do
    @stand_in.script("pass_review", T::Outcome.completed({})).script("fail_review", T::Outcome.completed({}))
    CASES.select { |kase| kase.operation == "give_verdict" }.each { |kase| send_case(kase) }

    assert_equal %w[pass_review fail_review], @stand_in.requests.map(&:command)
  end

  test "a call without a body accepts an empty object" do
    kase = CASES.find { |candidate| candidate.operation == "heartbeat_task" }
    @stand_in.script("heartbeat", T::Outcome.completed(kase.result))
    send_case(kase, raw: "{}")

    assert_response :ok
    assert_equal({ "id" => TASK }, @stand_in.requests.sole.params)
  end

  test "the engine's errors become the transport errors" do
    kase = CASES.find { |candidate| candidate.operation == "heartbeat_task" }
    { T::NotFound => [ :not_found, "not_found" ], Leverage::Idempotency::KeyReused => [ :unprocessable_content, "key_reused" ],
      T::Invalid => [ :unprocessable_content, "invalid" ] }.each do |error, (status, code)|
      @stand_in.script("heartbeat") { |_request| raise error, "made up" }
      send_case(kase)

      assert_error status, code
    end
  end

  READS.each do |operation, path|
    test "#{operation} with no token or another kind's token is 401" do
      [ nil, @scenario.owner_token, @scenario.helper_token ].each do |token|
        get_as(path, token: token)

        assert_error :unauthorized, "unauthenticated"
      end
    end
  end

  # get_command

  def stored_command(key:, seat: @builder, outcome: "completed", result: { "lease_due_at" => "2026-01-01T00:00:00Z" },
                     refusal: nil, command: "heartbeat")
    Command.create!(workspace_id: seat.workspace_id, caller_kind: "seat", caller_id: seat.id, key: key, command: command,
      request_hash: "made-up-hash", outcome: outcome, result: result, refusal: refusal)
  end

  test "get_command answers the stored outcome body of a command this seat sent" do
    stored_command(key: "key-done")
    stored_command(key: "key-refused", outcome: "refused", result: nil,
      refusal: { "code" => "lease_expired", "rule_id" => nil, "reason" => nil }, command: "submit")

    get_as "/v1/commands/key-done"

    assert_response :ok
    assert_equal({ "key" => "key-done", "command" => "heartbeat", "outcome" => "completed",
                   "result" => { "lease_due_at" => "2026-01-01T00:00:00Z" }, "refusal" => nil }, response.parsed_body)
    assert_response_matches_contract

    get_as "/v1/commands/key-refused"

    assert_response :ok
    assert_equal "refused", response.parsed_body["outcome"]
    assert_equal "lease_expired", response.parsed_body.dig("refusal", "code")
    assert_nil response.parsed_body["result"]
    assert_response_matches_contract
  end

  test "get_command is 404 for an unknown key, for another seat's key and for another workspace's" do
    other = @scenario.seat(role: "builder")
    stored_command(key: "key-of-another", seat: other)
    stranger = Scenario.new
    stored_command(key: "key-of-a-stranger", seat: stranger.seat(role: "builder"))
    [ "key-unknown", "key-of-another", "key-of-a-stranger", "x" * 300 ].each do |key|
      get_as "/v1/commands/#{key}"

      assert_error :not_found, "not_found"
    end
  end

  test "get_command sets read_at once, under the workspace lock, and leaves the row otherwise as it was" do
    row = stored_command(key: "key-read")
    row.update_columns(read_at: nil)

    get_as "/v1/commands/key-read"

    first = row.reload.read_at
    assert_not_nil first
    assert_equal "completed", row.outcome
    get_as "/v1/commands/key-read"

    assert_equal first, row.reload.read_at
  end

  # The briefing reads

  BRIEFING = AgentCallsTest.example("BriefingResponse")["briefing"].freeze

  # Puts a Leverage::Briefing whose build answers the briefing of the
  # contract's example in place for the block (WP3 owns the real one), and
  # returns the calls it was given.
  def with_briefing
    calls = []
    created = !Leverage.const_defined?(:Briefing, false)
    mod = created ? Leverage.const_set(:Briefing, Module.new) : Leverage::Briefing
    original = (mod.singleton_class.instance_method(:build) if mod.singleton_class.method_defined?(:build, false))
    mod.define_singleton_method(:build) do |subject, seat|
      calls << [ subject, seat ]
      BRIEFING
    end
    yield calls
  ensure
    if created
      Leverage.send(:remove_const, :Briefing)
    elsif original
      mod.define_singleton_method(:build, original)
    else
      mod.singleton_class.send(:remove_method, :build)
    end
  end

  test "get_task_briefing answers the briefing, the work reference and the notes of the task's failed reviews" do
    task = @scenario.task(state: "working", builder: @builder, work_reference: "~/work/made-up")
    first = Review.create!(workspace_id: task.workspace_id, task_id: task.id, round: 0, verdict: "failed", notes: "Made-up first note.")
    second = Review.create!(workspace_id: task.workspace_id, task_id: task.id, round: 1, verdict: "failed", notes: nil)
    Review.create!(workspace_id: task.workspace_id, task_id: task.id, round: 2, verdict: "passed", notes: "Not a failure.")

    with_briefing do |calls|
      get_as "/v1/tasks/#{task.id}/briefing"

      assert_response :ok
      assert_equal [ [ task.id, @builder.id ] ], calls.map { |subject, seat| [ subject.id, seat.id ] }
    end
    assert_equal({ "briefing" => BRIEFING, "work_reference" => "~/work/made-up",
                   "review_notes" => [ { "review_id" => first.id, "round" => 0, "notes" => "Made-up first note." },
                                       { "review_id" => second.id, "round" => 1, "notes" => nil } ] }, response.parsed_body)
    assert_response_matches_contract
  end

  test "get_task_briefing is 404 for a task this seat does not hold, one past its lease, and one that does not exist" do
    mine = @scenario.task(state: "working", builder: @builder)
    other = @scenario.task(state: "working", builder: @scenario.seat(role: "builder"))
    ready = @scenario.task(state: "ready")
    stranger = Scenario.new.task(state: "ready")
    with_briefing do |calls|
      [ other.id, ready.id, stranger.id, SecureRandom.uuid, "not-a-uuid" ].each do |id|
        get_as "/v1/tasks/#{id}/briefing"

        assert_error :not_found, "not_found"
      end
      mine.update_columns(lease_due_at: @scenario.database_now - 1)
      get_as "/v1/tasks/#{mine.id}/briefing"

      assert_error :not_found, "not_found"
      assert_empty calls
    end
  end

  # Milestone 4 review, finding 12 (RD-38): a review failed by a rule at
  # "when the review has passed" carries, after the reviewer's notes, the
  # rule's name and the check's reason, so the builder sent back sees why.
  test "get_task_briefing's notes of a review a rule failed name the rule and its reason" do
    task = @scenario.task(state: "working", builder: @builder)
    rule = @scenario.rule(hook: "task.before_done", name: "Made-up rule at Done")
    check = @scenario.rule_check(task, rule: rule, result: "failed", reason: "Made-up reason the rule failed.")
    review = Review.create!(workspace_id: task.workspace_id, task_id: task.id, round: 0, verdict: "failed",
      notes: "Made-up reviewer notes.", failed_rule_check_id: check.id)

    get_as "/v1/tasks/#{task.id}/briefing"

    assert_response :ok
    assert_equal [ { "review_id" => review.id, "round" => 0,
                     "notes" => "Made-up reviewer notes.\n\nMade-up rule at Done: Made-up reason the rule failed." } ],
      response.parsed_body.fetch("review_notes")
    assert_response_matches_contract
  end

  # Milestone 4 review, finding 13 (L392, RE-5): a provisional claimant
  # holds the Ready task with no lease; it gets no briefing until its
  # claim gate passes.
  test "get_task_briefing is 404 for a Ready task the seat holds provisionally" do
    task = @scenario.task(state: "ready")
    task.update_columns(holder_seat_id: @builder.id, lease_due_at: nil)

    get_as "/v1/tasks/#{task.id}/briefing"

    assert_error :not_found, "not_found"
  end

  test "get_review_briefing answers the briefing of the review this reviewer holds, with no notes" do
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review", work_reference: "~/work/made-up")
    review = @scenario.review(task, reviewer: reviewer)
    Review.create!(workspace_id: task.workspace_id, task_id: task.id, round: 7, verdict: "failed", notes: "Not shown to a reviewer.")

    with_briefing do |calls|
      get_as "/v1/reviews/#{review.id}/briefing", token: @scenario.token_for(reviewer)

      assert_response :ok
      assert_equal [ [ review.id, reviewer.id ] ], calls.map { |subject, seat| [ subject.id, seat.id ] }
    end
    assert_equal({ "briefing" => BRIEFING, "work_reference" => "~/work/made-up", "review_notes" => [] }, response.parsed_body)
    assert_response_matches_contract
  end

  test "get_review_briefing is 404 for a review another seat holds, one already given a verdict and one that does not exist" do
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    done = @scenario.task(state: "done")
    finished = Review.where(task_id: done.id).sole
    with_briefing do |calls|
      get_as "/v1/reviews/#{review.id}/briefing"
      assert_error :not_found, "not_found"

      [ finished.id, SecureRandom.uuid, "not-a-uuid" ].each do |id|
        get_as "/v1/reviews/#{id}/briefing", token: @scenario.token_for(reviewer)

        assert_error :not_found, "not_found"
      end
      assert_empty calls
    end
  end
end
