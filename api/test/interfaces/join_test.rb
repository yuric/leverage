require "test_helper"
require_relative "../support/http_calls"

class JoinTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  ADDRESS = "http://127.0.0.1:41234".freeze
  MCP_FALLBACK = "Ask your user for the path of LeverageMCP, inside the Leverage app.".freeze
  NEXT_KINDS = {
    "builder" => %w[command briefing_changed resume answer action rework task none],
    "reviewer" => %w[command briefing_changed review none],
    "planner" => %w[command job none],
    "orchestrator" => %w[command job none],
    "general" => %w[command briefing_changed resume answer action rework job review task none]
  }.freeze

  setup do
    @scenario = Scenario.new(lease_length_seconds: 900)
  end

  def join(seat, connection: nil, host: "127.0.0.1:41234", token: @scenario.token_for(seat))
    host! host
    get HttpCalls.path("get_join"), params: (connection.nil? ? {} : { connection: connection }),
      headers: (token ? { "Authorization" => "Bearer #{token}" } : {})
  end

  Leverage::Contract.roles.fetch("roles").each do |entry|
    role = entry.fetch("role")
    %w[http mcp].each do |connection|
      test "#{role} receives the #{connection} instructions and its exact operations" do
        seat = @scenario.seat(role: role, name: "Made-up #{role} agent")
        join(seat, connection: connection)

        assert_response :ok
        assert_response_matches_contract
        assert_equal [ role, connection ], response.parsed_body.values_at("role", "connection")
        text = response.parsed_body.fetch("text")
        article = role == "orchestrator" ? "an" : "a"
        assert_equal "You are connected to Leverage as #{article} #{role} agent.", text.lines.first.chomp
        known_kinds = Leverage::Contract.registry.fetch("next_kinds")
        kinds = text.scan(/^- `([a-z_]+)`: /).flatten.select { |kind| known_kinds.include?(kind) }
        assert_equal NEXT_KINDS.fetch(role), kinds

        assert_includes text, "Never stop this loop on your own."
        assert_includes text, "If any call answers 401, your token has ended: the owner removed this agent or made a new prompt for it. Stop at once, do not retry, and tell your user."
        assert_includes text, "A paused or disabled seat gets `none`. Keep polling."
        assert_includes text, "Use the token from your landing prompt as a bearer token on every call."
        refute response.body.include?(@scenario.token_for(seat)), "The response contains the bearer token"
        refute response.body.include?(seat.token_hash), "The response contains the token digest"
        refute_match(/<%|%>/, text)

        allowed = entry.fetch("operations")
        if connection == "http"
          assert_includes text, seat.name
          assert_includes text, ADDRESS
          assert_includes text, "Ask `GET /v1/next?wait=30` again as soon as it answers."
          assert_includes text, "Leverage counts you offline 90 seconds after your last `GET /v1/next`."
          assert_includes text, "Do not print it, write it into a file or send it to anything but this server."
          allowed = allowed.select { |id| Leverage::Http::RouteTable.serves?(id) }
          expected = allowed.map do |id|
            [ id, *HttpCalls.operation(id).values_at("method", "path") ]
          end
          assert_equal expected, text.scan(/^- `([a-z_]+)`: `(GET|POST) (\S+)`$/)
        else
          refute_includes text, seat.name
          assert_includes text, "Call `get_next` with `wait: 30` again as soon as it answers."
          assert_includes text, "Leverage counts you offline 90 seconds after your last `get_next`."
          assert_includes text, "Do not print it or send it to anything but this server. Write it only into the MCP settings below."
          assert_includes text, %("LEVERAGE_API_URL": "#{ADDRESS}")
          assert_includes text, %("LEVERAGE_SEAT_ROLE": "#{role}")
          assert_includes text, %("LEVERAGE_SEAT_TOKEN": "the token from your landing prompt")
          assert_includes text, "Add these settings to your MCP client, or ask your user to, then use the tools."
          assert_equal allowed, text.scan(/^- `([a-z_]+)`$/).flatten
        end

        Leverage::Contract.registry.fetch("operations").select { |operation| operation.fetch("tag") == "agent" }.each do |operation|
          id = operation.fetch("operation_id")
          refute_includes text, "`#{id}`" unless allowed.include?(id)
        end
        assert_role_instructions(text, entry, connection)
      end
    end
  end

  test "HTTP is the default connection" do
    seat = @scenario.seat
    join(seat)
    assert_response :ok
    default = response.parsed_body
    assert_equal "http", default.fetch("connection")
    join(seat, connection: "http")
    assert_response :ok
    assert_equal default, response.parsed_body
  end

  test "a one-second lease gives the HTTP agent a positive heartbeat interval" do
    @scenario.workspace.update!(lease_length_seconds: 1)
    join(@scenario.seat)

    assert_response :ok
    assert_includes response.parsed_body.fetch("text"), "Renew it at least every 0.3 seconds."
  end

  test "missing, wrong-kind, ended and removed bearer tokens answer 401" do
    seat = @scenario.seat
    ended = @scenario.end_token(@scenario.seat)
    removed = @scenario.remove(@scenario.seat)
    [ nil, @scenario.owner_token, @scenario.helper_token, @scenario.token_for(ended), @scenario.token_for(removed) ].each do |token|
      join(seat, token: token)
      assert_response :unauthorized
      assert_response_matches_contract
      assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
    end
  end

  test "unknown connection values and unusable addresses answer 400" do
    seat = @scenario.seat
    [ "ssh", "", [ "http" ], { kind: "http" } ].each do |connection|
      join(seat, connection: connection)
      assert_malformed
    end
    %w[http mcp].each do |connection|
      join(seat, connection: connection, host: "host;rm")
      assert_malformed
      refute_includes response.body, "host;rm"
    end
  end

  test "joining in any state does not update presence or write an event or a command" do
    seat = @scenario.seat(role: "general", credential: @scenario.credential, last_polled_at: @scenario.database_now - 120)
    before = [ seat.last_polled_at, Event.count, Command.count ]
    join(seat)
    assert_response :ok
    instructions = response.parsed_body

    [ { paused: true }, { paused: false, enabled: false } ].each do |state|
      seat.update!(state)
      join(seat)
      assert_response :ok
      assert_equal instructions, response.parsed_body
      assert_equal before, [ seat.reload.last_polled_at, Event.count, Command.count ]
    end
  end

  test "HTTP suppresses tokens in the stored seat name" do
    seat = @scenario.seat
    token = @scenario.token_for(seat)
    seat.update!(name: "Made-up agent #{token}")
    join(seat)
    assert_response :ok
    refute response.body.include?(token), "The response contains the bearer token"
    assert_includes response.parsed_body.fetch("text"), "Made-up agent [FILTERED]"
  end

  test "MCP renders only a usable command and otherwise asks for its path" do
    seat = @scenario.seat
    previous = ENV["LEVERAGE_MCP_COMMAND"]
    valid = "/Applications/Leverage App.app/Contents/MacOS/LeverageMCP"
    ENV["LEVERAGE_MCP_COMMAND"] = valid
    join(seat, connection: "mcp")
    assert_response :ok
    text = response.parsed_body.fetch("text")
    assert_includes text, %("command": "#{valid}")
    refute_includes text, MCP_FALLBACK

    token_path = "/made-up/#{@scenario.token_for(seat)}/LeverageMCP"
    [ nil, "/bin/Other", "/bad;command/LeverageMCP", "/good/LeverageMCP\n", token_path ].each do |command|
      ENV["LEVERAGE_MCP_COMMAND"] = command
      join(seat, connection: "mcp")
      assert_response :ok
      text = response.parsed_body.fetch("text")
      refute response.body.include?(@scenario.token_for(seat)), "The response contains the bearer token"
      assert_includes text, MCP_FALLBACK
      refute_includes text, %("command":)
      refute text.include?(command), "The response contains the unusable command" if command
    end
  ensure
    ENV["LEVERAGE_MCP_COMMAND"] = previous
  end

  private

  def assert_malformed
    assert_response :bad_request
    assert_response_matches_contract
    assert_equal "malformed", response.parsed_body.dig("error", "code")
  end

  def assert_role_instructions(text, entry, connection)
    role = entry.fetch("role")
    if role == "general"
      assert_equal entry.fetch("job_rules"), text.lines.map(&:chomp).select { |line| entry.fetch("job_rules").include?(line) }
      refute_match(/role file/i, text)
      assert_includes text, "Take one task, review or job at a time."
    else
      assert_match(/Read your role file/, text)
    end

    kinds = NEXT_KINDS.fetch(role)
    if kinds.include?("task")
      assert_includes text, "Read the briefing with `get_task_briefing` before any work on a task"
      assert_includes text, "`acknowledge_task_briefing`"
      assert_match(/release.*`release_task`/i, text)
      assert_match(/ask.*`ask_question`/i, text)
      assert_match(/`start_action` before.*`report_action_done` after/, text)
    end
    if kinds.include?("review")
      assert_includes text, "Read the briefing with `get_review_briefing` before any work on a review"
      assert_includes text, "`acknowledge_review_briefing`"
      assert_match(/release.*`release_review`/i, text)
      assert_match(/fail.*review.*notes/i, text)
    end
    if kinds.include?("briefing_changed")
      assert_includes text, "900 seconds"
      if connection == "http"
        assert_includes text, "at least every 300 seconds"
        assert_includes text, "Call `heartbeat_task` while holding a task." if kinds.include?("task")
        assert_includes text, "Call `heartbeat_review` while holding a review." if kinds.include?("review")
        assert_includes text, "`GET /v1/next?wait=0` between steps"
      else
        assert_match(/MCP server renews.*while you keep making tool calls/, text)
        assert_includes text, "It checks every minute and renews when you made a tool call in the last 10 minutes."
        assert_includes text, "`get_next` with `wait: 0` between steps"
      end
    end
    if kinds.include?("job")
      poll = connection == "http" ? "`GET /v1/next?wait=0`" : "`get_next` with `wait: 0`"
      assert_includes text, "#{poll} at least once a minute"
      assert_includes text, "`submit_job_result`"
      assert_match(/pass a question to the owner/i, text) unless role == "planner"
    end
  end
end
