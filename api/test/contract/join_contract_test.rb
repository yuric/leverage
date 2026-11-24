require_relative "contract_helper"
require_relative "columns_test"

# The join call and the one landing prompt (the owner's request of
# 2026-11-23, contract decisions GA-12 to GA-17). A seat that connects on
# its own lands from one short prompt that carries its token; the agent
# then reads its whole instructions from GET /v1/join. The prompt is issued
# by an owner command, which also issues the seat's token and ends the one
# before it, so connect_seat no longer returns a token. Every name is read
# from the contract files.
class JoinContractTest < Minitest::Test
  include ContractTestHelpers

  def doc = Leverage::Contract.openapi
  def schemas = doc.fetch("components").fetch("schemas")
  def sm = Leverage::Contract.state_machine

  def operation(operation_id)
    doc.fetch("paths").each_value do |item|
      item.each_value { |op| return op if op.is_a?(Hash) && op["operationId"] == operation_id }
    end
    flunk "no operation #{operation_id} in openapi.json"
  end

  def registry_operation(operation_id)
    registry.fetch("operations").find { |op| op["operation_id"] == operation_id }
  end

  def deref(node)
    node = node["$ref"].delete_prefix("#/").split("/").reduce(doc) { |part, key| part.fetch(key) } while node.is_a?(Hash) && node["$ref"]
    node
  end

  def response_ref(operation_id, status)
    response = deref(operation(operation_id).fetch("responses").fetch(status))
    response.dig("content", "application/json", "schema", "$ref")
  end

  def parameters(operation_id) = operation(operation_id).fetch("parameters", []).map { |parameter| deref(parameter) }

  def validator(component) = JSONSchemer.openapi(doc).ref("#/components/schemas/#{component}")

  # GA-12: one agent call, open to every role.
  def test_get_join_is_an_agent_read_every_role_may_make
    entry = registry_operation("get_join")
    refute_nil entry, "get_join is not a registry operation"
    assert_equal [ "GET", "/v1/join", "any", [ "read" ], "agent" ], entry.values_at("method", "path", "caller", "commands", "tag")
    Leverage::Contract.roles.fetch("roles").each do |role|
      assert_includes role.fetch("operations"), "get_join", role.fetch("role")
    end
  end

  def test_get_join_answers_the_instructions_for_one_connection
    op = operation("get_join")
    assert_equal [ { "seatBearer" => [] } ], op["security"]
    refute_includes parameters("get_join").map { |parameter| parameter["name"] }, "Idempotency-Key"
    connection = parameters("get_join").find { |parameter| parameter["name"] == "connection" }
    refute_nil connection, "get_join takes the connection"
    assert_equal "query", connection["in"]
    assert_equal %w[http mcp], connection.dig("schema", "enum")
    assert_equal "http", connection.dig("schema", "default")
    assert_equal "#/components/schemas/JoinInstructions", response_ref("get_join", "200")
    %w[400 401].each { |status| assert op["responses"].key?(status), "get_join lacks #{status}" }
    refute op["responses"].key?("409"), "get_join refuses nothing: a disabled or paused seat reads it too"
  end

  # GA-14: JSON with a text field, as every answer of the interface is.
  def test_the_join_instructions_are_text_for_a_role_and_a_connection
    shape = schemas.fetch("JoinInstructions")
    assert_equal false, shape["additionalProperties"]
    assert_equal %w[connection role text], shape.fetch("required").sort
    assert_equal %w[connection role text], shape.fetch("properties").keys.sort
    assert_equal Leverage::Contract.list("seat_roles"), shape.dig("properties", "role", "enum")
    assert_equal %w[http mcp], shape.dig("properties", "connection", "enum")
    assert_includes shape.fetch("description"), "never"
    assert_equal %w[text role connection].sort, ColumnsTest::NOT_COLUMNS.fetch("JoinInstructions").sort
  end

  # GA-13: the read became a command that issues the token and the prompt.
  def test_the_landing_prompt_is_issued_by_an_owner_command
    assert_nil registry_operation("get_landing_prompt"), "the landing prompt is no longer a read"
    refute schemas.key?("LandingPrompt"), "LandingPrompt went with the read"
    entry = registry_operation("issue_landing_prompt")
    refute_nil entry, "issue_landing_prompt is not a registry operation"
    assert_equal [ "POST", "/v1/owner/seats/{id}/landing-prompt", "owner", [ "issue_landing_prompt" ], "owner" ],
      entry.values_at("method", "path", "caller", "commands", "tag")
    op = operation("issue_landing_prompt")
    assert_includes parameters("issue_landing_prompt").map { |parameter| parameter["name"] }, "Idempotency-Key"
    assert_equal [ { "ownerSession" => [] } ], op["security"]
    request = op.dig("requestBody", "content", "application/json", "schema", "$ref")
    assert_equal "#/components/schemas/IssueLandingPromptRequest", request
    body = schemas.fetch("IssueLandingPromptRequest")
    assert_equal %w[connection], body.fetch("required")
    assert_equal %w[http mcp], body.dig("properties", "connection", "enum")
    assert_equal "#/components/schemas/LandingPromptIssuedCompleted", response_ref("issue_landing_prompt", "200")
    %w[400 401 404 409].each { |status| assert op["responses"].key?(status), "issue_landing_prompt lacks #{status}" }
  end

  def test_the_issued_prompt_carries_the_token_once_and_a_repeat_carries_neither
    issued = schemas.fetch("LandingPromptIssued")
    assert_equal %w[connection seat_id seat_token text], issued.fetch("required").sort
    repeated = schemas.fetch("LandingPromptIssuedRepeated")
    assert_empty %w[seat_token text] & repeated.fetch("properties").keys
    envelope = { "key" => "k", "command" => "issue_landing_prompt", "outcome" => "completed", "refusal" => nil }
    first = issued.fetch("examples").first
    assert validator("LandingPromptIssuedCompleted").valid?(envelope.merge("result" => first))
    refute validator("LandingPromptIssuedCompleted").valid?(envelope.merge("result" => first.except("text")))
    again = repeated.fetch("examples").first
    assert validator("LandingPromptIssuedCompleted").valid?(envelope.merge("result" => again))
    # The example prompt is made up: it names a placeholder, never a token.
    refute_match(/\blv[sho]_[A-Za-z0-9_-]{8,}/, JSON.generate(issued.fetch("examples")))
    assert_equal %w[text connection].sort, ColumnsTest::NOT_COLUMNS.fetch("LandingPromptIssued").sort
  end

  def test_the_command_is_registered_with_a_row_that_writes_no_event
    assert_includes registry.fetch("commands"), "issue_landing_prompt"
    entry = sm.fetch("commands").find { |command| command["command"] == "issue_landing_prompt" }
    refute_nil entry, "issue_landing_prompt has no commands entry"
    assert_equal [ false, false, false ], entry.values_at("work_call", "blocked_by_hold", "allowed_while_pending")
    rows = sm.fetch("groups").flat_map { |group| group["rows"] }.select { |row| row["command"] == "issue_landing_prompt" }
    assert_equal 1, rows.size
    assert_equal [ "owner" ], rows.first["who"]
    assert_equal [], rows.first["events"]
    assert_equal [], rows.first["side_events"]
  end

  # GA-13: a seat gets its token only from the call that issues it: the
  # helper's issue_seat_token for a seat the app runs, this prompt for one
  # that connects on its own.
  def test_connect_seat_returns_no_token
    assert_equal "#/components/schemas/SeatConnectedCompleted", response_ref("connect_seat", "200")
    assert_equal %w[seat_id], schemas.fetch("SeatConnected").fetch("properties").keys
    refute schemas.key?("SeatConnectedRepeated"), "a repeat of connect_seat answers the same result"
    envelope = { "key" => "k", "command" => "connect_seat", "outcome" => "completed", "refusal" => nil }
    assert validator("SeatConnectedCompleted").valid?(envelope.merge("result" => { "seat_id" => "00000000-0000-4000-8000-000000000001" }))
    refute validator("SeatConnectedCompleted").valid?(envelope.merge("result" => { "seat_id" => "00000000-0000-4000-8000-000000000001", "seat_token" => "made-up" }))
  end

  def test_the_readme_records_what_the_join_call_added
    readme = File.read(File.join(CONTRACT_ROOT, "README.md"))
    section = readme.split(/^## /).find { |part| part.start_with?("What the join call added") }
    refute_nil section, "README.md has no section for the join call"
    %w[get_join issue_landing_prompt JoinInstructions LandingPromptIssued SeatConnected LEVERAGE_MCP_COMMAND].each do |name|
      assert_includes section, name
    end
  end

  def test_the_decisions_record_the_join_call
    decisions = File.read(File.join(CONTRACT_ROOT, "decisions.md"))
    (12..17).each { |number| assert_match(/\*\*GA-#{number}\*\*/, decisions, "GA-#{number}") }
  end
end
