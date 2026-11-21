require_relative "trace_runner"
require_relative "http_calls"

# TraceRunner with HTTP in place of Transitions.apply (milestone 2 plan
# §5.2, WP17; milestone 3 plan WP10, HT-4): a golden trace sent through the
# three interfaces, with the real entries behind them, and compared as the
# engine run compares it, event for event and step row for step row.
#
# The setup the trace names is built over HTTP too, the way the app and
# the helper build it: the owner issues the helper's token, adds the logins
# in the trace's order (the helper passes their checks and takes their first
# reading; a login the setup has signed out is then verified and found signed
# out), and connects each seat on its login (the helper picks the seat's
# token up, reports its run started and the start request finished). Only
# the owner and the session come from Scenario, because a test worker's
# database may already hold an owner.
#
# Then each command is sent with its caller's token and its key. After
# every command the runner is the helper too: it asks get_helper_next until
# nothing is queued, and answers each start_seat as the helper hands a run
# over (HD-2): it picks the seat's new token up, reports the run started on
# the request's credential and the request finished. Those calls write no
# event, so they sit between the trace's commands without changing what is
# compared. A request the trace answers itself (Verify, Sign in again) is
# only picked up, as the helper does before it runs the checks.
#
# A timer (caller app) runs as the sweep runs it, through the engine: no
# interface serves the app's own commands.
class HttpTraceRunner < TraceRunner
  ACKNOWLEDGED = { "acknowledge_briefing" => "get_task_briefing",
                   "acknowledge_review_briefing" => "get_review_briefing" }.freeze

  attr_reader :tokens, :picked_up

  # test - the ActionDispatch::IntegrationTest that sends the calls.
  # next_before - { index => kind }: what GET /v1/next answers the caller
  #   just before the command at that index (0-based).
  # after_command - called with (index, runner) after each command and the
  #   helper's turn, for checks a test makes between commands.
  # trace - a changed copy of the trace, as TraceRunner takes one.
  def initialize(test, name, trace: nil, next_before: {}, after_command: nil)
    super(name, trace: trace)
    @test = test
    @tokens = {}
    @next_before = next_before
    @after_command = after_command
    @picked_up = []
  end

  def owner_token = @tokens.fetch(trace.dig("setup", "users", 0, "id"))

  def helper_token = @helper_token

  # The helper's turn after a command: every queued request, oldest first;
  # a start_seat is handed over, any other request is picked up.
  def helper_turn
    while (request = http("get_helper_next", token: @helper_token, query: { "wait" => 0 }).fetch("request"))
      if request.fetch("kind") == "start_seat"
        start_run(request)
      else
        @picked_up << request
      end
    end
  end

  private

  # --- setup -------------------------------------------------------------

  def seed
    @scenario = Scenario.new(**trace.fetch("setup").fetch("settings").transform_keys(&:to_sym))
    owner = scenario.owner
    bind_symbol(trace.dig("setup", "users", 0, "id"), owner.id, "setup")
    @tokens[trace.dig("setup", "users", 0, "id")] = scenario.owner_token
    seed_helper(trace.dig("setup", "helpers", 0))
    trace.dig("setup", "credentials").sort_by { |row| row.fetch("position") }.each { |row| seed_credential(row) }
    trace.dig("setup", "seats").each { |row| seed_seat(row) }
    @setup_seq = scenario.workspace.reload.last_seq
  end

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
    @tokens[row.fetch("id")] = @helper_token
  end

  def checks(names, failed: {})
    names.map do |check|
      { "check" => check, "passed" => !failed.key?(check), "failure" => failed[check] }
    end
  end

  def finished(names, failed: {})
    { "result" => { "outcome" => "finished", "tool_version" => "9.9.9-made-up", "plan" => nil, "account_email" => nil,
                    "checks" => checks(names, failed: failed) } }
  end

  # Add credential, and the helper's checks for it, all passed; a login the
  # setup has signed out is then verified, and the helper finds it signed
  # out (credential.signed_out with no seat, as Verify writes it).
  def seed_credential(row)
    id = SecureRandom.uuid
    result = http("add_credential", token: owner_token,
      body: { "credential_id" => id, "kind" => row.fetch("kind"), "provider" => row.fetch("provider"),
              "name" => row.fetch("name"), "masked_label" => nil, "model" => row.fetch("model"),
              "effort" => row.fetch("effort"), "strength_rank" => row.fetch("strength_rank") }).fetch("result")
    request = next_request("run_add_checks")
    @test.assert_equal result.fetch("helper_request_id"), request.fetch("id")
    names = %w[tool_installed signed_in test_prompt]
    names.each do |check|
      http("report_request_progress", token: @helper_token, ids: { "id" => request.fetch("id") },
        body: { "check" => check, "state" => "passed", "failure" => nil, "install" => nil })
    end
    http("report_request_result", token: @helper_token, ids: { "id" => request.fetch("id") }, body: finished(names))
    take_first_reading(id)
    @test.assert_equal "active", Credential.find(id).state
    @test.assert_equal row.fetch("position"), Credential.find(id).position, "#{row.fetch("id")}: the order of adding"
    bind_symbol(row.fetch("id"), id, "setup")
    sign_out_by_verify(id) if row.fetch("state") == "signed_out"
    @test.assert_nil row["limited_until"], "#{row.fetch("id")}: a limited setup login is not built over HTTP"
  end

  def take_first_reading(id)
    request = next_request("read_usage")
    @test.assert_equal id, request.fetch("credential_id")
    http("report_reading", token: @helper_token, ids: { "id" => id },
      body: { "credential_id" => id, "observed_at" => scenario.database_now.utc.iso8601(6), "state" => "unavailable",
              "tool_version" => nil, "figures" => [], "resets" => nil })
    http("report_request_result", token: @helper_token, ids: { "id" => request.fetch("id") }, body: finished(%w[reading_taken]))
  end

  def sign_out_by_verify(id)
    http("verify_credential", token: owner_token, ids: { "id" => id })
    request = next_request("verify")
    http("report_request_result", token: @helper_token, ids: { "id" => request.fetch("id") },
      body: finished(%w[tool_installed signed_in], failed: { "signed_in" => "not_signed_in" }))
    @test.assert_equal "signed_out", Credential.find(id).state
  end

  # Connect a seat the app runs; the helper picks its token up and reports
  # its run started.
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
    bind_symbol(row.fetch("id"), seat_id, "setup")
    start_run(request)
  end

  def next_request(kind)
    request = http("get_helper_next", token: @helper_token, query: { "wait" => 0 }).fetch("request")
    @test.refute_nil request, "the helper is asked to #{kind}"
    @test.assert_equal kind, request.fetch("kind")
    request
  end

  # The helper's hand-over of a start_seat (HD-2): the seat's new token,
  # the run started on the request's credential, the request finished.
  def start_run(request)
    seat_id = request.fetch("seat_id")
    pickup = http("issue_seat_token", token: @helper_token, ids: { "id" => request.fetch("id") }).fetch("result")
    http("report_run_started", token: @helper_token, ids: { "id" => seat_id },
      body: { "credential_id" => request.fetch("credential_id"), "observed_at" => Time.current.utc.iso8601(6),
              "tool_version" => "9.9.9-made-up" })
    http("report_request_result", token: @helper_token, ids: { "id" => request.fetch("id") },
      body: { "result" => { "outcome" => "finished", "tool_version" => "9.9.9-made-up", "plan" => nil,
                            "account_email" => nil, "checks" => [] } })
    @tokens[@symbols.fetch(seat_id)] = pickup.fetch("seat_token")
    @test.assert_equal request.fetch("credential_id"), Seat.find(seat_id).run_credential_id, "HD-3: the run's login"
  end

  # --- the commands ------------------------------------------------------

  def run_command(command, index, timer: nil)
    raise ArgumentError, "#{name}: a timer at the time of a command is not sent over HTTP" if timer

    where = label(command, index)
    @command_seconds = seconds(command.fetch("at"))
    token = @tokens.fetch(command.fetch("caller")) { raise ArgumentError, "#{where}: no token for #{command.fetch("caller")}" }
    ask_next(token, @next_before.fetch(index), where) if @next_before.key?(index)
    operation_id = command.fetch("operation_id")
    ids = resolve(command.fetch("path_params"))
    body = resolve(command.fetch("body"))
    body["briefing_hash"] = briefing_hash(ACKNOWLEDGED.fetch(command.fetch("command")), token, ids) if body.key?("briefing_hash")
    body = nil if body.empty? && !Leverage::Http::RequestSchema.schema_pointer(operation_id)

    before = scenario.workspace.reload.last_seq
    @test.call(operation_id, token: token, key: key_id(command.fetch("key")), ids: ids, body: body)
    @test.assert_response_matches_contract
    outcome = outcome_of(@test.response, where)
    if outcome
      written = Event.where(workspace_id: workspace_id).where("seq > ?", before).order(:seq).to_a
      compare_outcome(command.fetch("expect"), outcome, where)
      compare_events(command.fetch("expect").fetch("events"), written, where)
      compare_steps([ command.fetch("expect") ], written, where)
      compare_result(command.fetch("expect")["result_fields"], outcome, where)
    end
    after(index)
  end

  def run_timer(command, index)
    super
    after(index)
  end

  def after(index)
    helper_turn
    @after_command&.call(index, self)
  end

  def outcome_of(response, where)
    unless [ 200, 409 ].include?(response.status)
      fail_at(where, "answered #{response.status}: #{response.body}")
      return
    end
    body = response.parsed_body
    unless body.key?("outcome")
      fail_at(where, "answered #{response.status}: #{response.body}")
      return
    end
    refused = body["refusal"]
    refusal = refused && Leverage::Transitions::Refusal.new(code: refused["code"], rule_id: refused["rule_id"],
      reason: refused["reason"])
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
