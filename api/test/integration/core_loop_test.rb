require "test_helper"
require_relative "../support/trace_runner"
require_relative "../support/http_calls"

# The core loop over HTTP (PRD L868, L893, L894; milestone 2 plan §5.2, WP17):
# golden trace 09, from Add task to Done through one failed review, sent
# through the three interfaces with the real entries behind them, then the
# replay and the log audit on the log it leaves.
#
# The setup the trace names is built over HTTP too, the way the app and the
# helper build it: the owner issues the helper's token, adds the two logins
# (the helper reports their checks passed) and connects the builder and the
# reviewer on them (the helper picks each seat's token up, reports its run
# started and the start request finished, as the helper does). Only the owner and the session come from Scenario, because a
# test worker's database may already hold an owner. Then each of the
# trace's nineteen commands is sent with its caller's token and its key,
# and TraceRunner compares the outcome, every event field for field and
# every step row for row with the trace. An acknowledgement sends the hash
# the seat's own briefing call answers. GET /v1/next is asked where the
# trace's next call depends on it: the builder is offered the task, the
# reviewer the review, and after the failed review the builder its rework.
class CoreLoopTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  TRACE = "09-core-loop-no-rules".freeze

  # TraceRunner with HTTP in place of Transitions.apply.
  class HttpTraceRunner < TraceRunner
    ACKNOWLEDGED = { "acknowledge_briefing" => "get_task_briefing",
                     "acknowledge_review_briefing" => "get_review_briefing" }.freeze

    # What GET /v1/next answers the caller just before the command at that
    # index (0-based), by the trace's commands.
    NEXT_BEFORE = { 2 => "task", 9 => "review", 12 => "rework" }.freeze

    def initialize(test)
      super(TRACE)
      @test = test
      @tokens = {}
    end

    attr_reader :tokens

    private

    # The setup over HTTP: the helper's token, the logins and the seats.
    def seed
      @scenario = Scenario.new(**trace.fetch("setup").fetch("settings").transform_keys(&:to_sym))
      owner = scenario.owner
      bind_symbol(trace.dig("setup", "users", 0, "id"), owner.id, "setup")
      @tokens[trace.dig("setup", "users", 0, "id")] = scenario.owner_token
      seed_helper(trace.dig("setup", "helpers", 0))
      trace.dig("setup", "credentials").each { |row| seed_credential(row) }
      trace.dig("setup", "seats").each { |row| seed_seat(row) }
      @setup_seq = scenario.workspace.reload.last_seq
    end

    def owner_token = @tokens.fetch(trace.dig("setup", "users", 0, "id"))

    def http(operation_id, token:, ids: {}, body: nil, query: nil, status: 200)
      key = @test.new_key("setup") if HttpCalls.operation(operation_id).fetch("method") == "POST"
      @test.call(operation_id, token: token, key: key, ids: ids, body: body, query: query)
      @test.assert_equal status, @test.response.status, "#{operation_id}: #{@test.response.body}"
      @test.assert_response_matches_contract
      body = @test.response.parsed_body
      @test.assert_equal "completed", body.fetch("outcome"), operation_id if key
      body
    end

    def seed_helper(row)
      result = http("issue_helper_token", token: owner_token, body: { "name" => row.fetch("name") }).fetch("result")
      bind_symbol(row.fetch("id"), result.fetch("helper_id"), "setup")
      @helper_token = result.fetch("helper_token")
    end

    # Add credential, and the helper's checks for it, all passed.
    def seed_credential(row)
      id = SecureRandom.uuid
      result = http("add_credential", token: owner_token,
        body: { "credential_id" => id, "kind" => row.fetch("kind"), "provider" => row.fetch("provider"),
                "name" => row.fetch("name"), "masked_label" => nil, "model" => row.fetch("model"),
                "effort" => row.fetch("effort"), "strength_rank" => row.fetch("strength_rank") }).fetch("result")
      request = next_request("run_add_checks")
      @test.assert_equal result.fetch("helper_request_id"), request.fetch("id")
      checks = %w[tool_installed signed_in test_prompt]
      checks.each do |check|
        http("report_request_progress", token: @helper_token, ids: { "id" => request.fetch("id") },
          body: { "check" => check, "state" => "passed", "failure" => nil, "install" => nil })
      end
      http("report_request_result", token: @helper_token, ids: { "id" => request.fetch("id") },
        body: { "result" => { "outcome" => "finished", "tool_version" => "9.9.9-made-up", "plan" => nil, "account_email" => nil,
                              "checks" => checks.map { |check| { "check" => check, "passed" => true, "failure" => nil } } } })
      @test.assert_equal "active", Credential.find(id).state
      bind_symbol(row.fetch("id"), id, "setup")
    end

    # Connect a seat the app runs; the helper picks its token up and
    # reports its run started.
    def seed_seat(row)
      result = http("connect_seat", token: owner_token,
        body: { "name" => row.fetch("name"), "role" => row.fetch("role"), "provider" => nil,
                "model" => row.fetch("model").presence, "effort" => row.fetch("effort").presence,
                "strength_rank" => row.fetch("strength_rank"), "credential_id" => bound(row.fetch("credential_id")) })
        .fetch("result")
      seat_id = result.fetch("seat_id")
      @test.assert_nil result.fetch("seat_token"), "a seat the app runs is never shown a token"
      request = next_request("start_seat")
      @test.assert_equal seat_id, request.fetch("seat_id")
      pickup = http("issue_seat_token", token: @helper_token, ids: { "id" => request.fetch("id") }).fetch("result")
      http("report_run_started", token: @helper_token, ids: { "id" => seat_id },
        body: { "credential_id" => bound(row.fetch("credential_id")), "observed_at" => Time.current.utc.iso8601,
                "tool_version" => "9.9.9-made-up" })
      http("report_request_result", token: @helper_token, ids: { "id" => request.fetch("id") },
        body: { "result" => { "outcome" => "finished", "tool_version" => "9.9.9-made-up", "plan" => nil, "account_email" => nil,
                              "checks" => [] } })
      bind_symbol(row.fetch("id"), seat_id, "setup")
      @tokens[row.fetch("id")] = pickup.fetch("seat_token")
    end

    def next_request(kind)
      request = http("get_helper_next", token: @helper_token, query: { "wait" => 0 }).fetch("request")
      @test.refute_nil request, "the helper is asked to #{kind}"
      @test.assert_equal kind, request.fetch("kind")
      request
    end

    # One of the trace's commands, over HTTP.
    def run_command(command, index, timer: nil)
      raise ArgumentError, "#{TRACE} has no timer" if timer

      where = label(command, index)
      caller = command.fetch("caller")
      token = @tokens.fetch(caller)
      ask_next(token, NEXT_BEFORE[index], where) if NEXT_BEFORE.key?(index)
      operation_id = command.fetch("operation_id")
      ids = resolve(command.fetch("path_params"))
      body = resolve(command.fetch("body"))
      body["briefing_hash"] = briefing_hash(ACKNOWLEDGED.fetch(command.fetch("command")), token, ids) if body.key?("briefing_hash")
      body = nil if body.empty? && !Leverage::Http::RequestSchema.schema_pointer(operation_id)

      before = scenario.workspace.reload.last_seq
      @test.call(operation_id, token: token, key: key_id(command.fetch("key")), ids: ids, body: body)
      @test.assert_response_matches_contract
      outcome = outcome_of(@test.response, where)
      return unless outcome

      written = Event.where(workspace_id: workspace_id).where("seq > ?", before).order(:seq).to_a
      compare_outcome(command.fetch("expect"), outcome, where)
      compare_events(command.fetch("expect").fetch("events"), written, where)
      compare_steps([ command.fetch("expect") ], written, where)
      compare_result(command.fetch("expect")["result_fields"], outcome, where)
    end

    def outcome_of(response, where)
      unless [ 200, 409 ].include?(response.status)
        fail_at(where, "answered #{response.status}: #{response.body}")
        return
      end
      body = response.parsed_body
      refusal = body["refusal"] && Leverage::Transitions::Refusal.new(**body.fetch("refusal").transform_keys(&:to_sym))
      Leverage::Transitions::Outcome.new(outcome: body.fetch("outcome"), result: body["result"], refusal: refusal)
    end

    # The hash of the briefing the seat reads through its own call.
    def briefing_hash(operation_id, token, ids)
      http(operation_id, token: token, ids: { "id" => ids.fetch("id") }).dig("briefing", "hash")
    end

    def ask_next(token, kind, where)
      item = http("get_next", token: token, query: { "wait" => 0 })
      fail_at(where, "GET /v1/next answered #{item.inspect}, expected #{kind}") unless item.fetch("kind") == kind
    end
  end

  test "trace 09 runs over HTTP through the three interfaces, and its log replays and passes the audit" do
    runner = HttpTraceRunner.new(self).run
    assert_empty runner.failures, runner.failures.join("\n")

    workspace_id = runner.workspace_id
    assert_empty Leverage::Replay.diff(workspace_id), "the replay of the log"
    assert_empty Leverage::LogAudit.call(workspace_id), "the log audit, setup included"

    task = Task.find_by!(workspace_id: workspace_id)
    owner_token = runner.tokens.fetch("$user:owner")
    call("get_task", token: owner_token, ids: { "id" => task.id })
    assert_response :ok
    assert_response_matches_contract
    assert_equal "done", response.parsed_body.dig("task", "state")
    assert_equal 1, Review.where(task_id: task.id, verdict: "failed").count, "exactly one review failed"

    call("list_events", token: owner_token, query: { "after_seq" => 0, "limit" => 500, "wait" => 0 })
    assert_response :ok
    assert_response_matches_contract
    task_events = Event.where(workspace_id: workspace_id, task_id: task.id).order(:seq).pluck(:type)
    expected = Leverage::Contract.trace(TRACE).fetch("commands").flat_map do |command|
      command.dig("expect", "events").map { |event| event.fetch("type") }
    end
    assert_equal expected, task_events
  end
end
