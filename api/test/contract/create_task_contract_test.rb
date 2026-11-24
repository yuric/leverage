require_relative "contract_helper"

# The agent's Add task (contract decisions UX-11 to UX-14, UX-16) and the
# model a seat that connects on its own reports (UX-9). create_task runs the
# owner's two commands, Add task then Complete contract, with the seat as
# caller; report_model runs change_seat as the seat. Neither adds a command
# or an event type.
class CreateTaskContractTest < Minitest::Test
  include ContractTestHelpers

  def doc = Leverage::Contract.openapi
  def schemas = doc.fetch("components").fetch("schemas")
  def sm = Leverage::Contract.state_machine
  def rows(command) = sm.fetch("groups").flat_map { |group| group["rows"] }.select { |row| row["command"] == command }
  def registry_operation(id) = registry.fetch("operations").find { |op| op["operation_id"] == id }
  def validator(component) = JSONSchemer.openapi(doc).ref("#/components/schemas/#{component}")

  def operation(operation_id)
    doc.fetch("paths").each_value do |item|
      item.each_value { |op| return op if op.is_a?(Hash) && op["operationId"] == operation_id }
    end
    flunk "no operation #{operation_id} in openapi.json"
  end

  def request_component(operation_id)
    operation(operation_id).dig("requestBody", "content", "application/json", "schema", "$ref").split("/").last
  end

  def test_create_task_is_an_agent_call_of_the_creator
    assert_includes Leverage::Contract.list("operation_callers"), "creator"
    entry = registry_operation("create_task")
    refute_nil entry, "create_task is not a registry operation"
    assert_equal [ "POST", "/v1/tasks", "creator", %w[add_task complete_contract], "agent" ],
      entry.values_at("method", "path", "caller", "commands", "tag")
    op = operation("create_task")
    assert_equal [ { "seatBearer" => [] } ], op["security"]
    assert_includes op.fetch("parameters").map { |parameter| parameter["$ref"] }, "#/components/parameters/IdempotencyKey"
    %w[200 202 400 401 409 422].each { |status| assert op["responses"].key?(status), "create_task lacks #{status}" }
  end

  def test_every_role_may_call_create_task_and_report_model
    Leverage::Contract.roles.fetch("roles").each do |role|
      assert_includes role.fetch("callers"), "creator", role["role"]
      assert_includes role.fetch("operations"), "create_task", role["role"]
      assert_includes role.fetch("operations"), "report_model", role["role"]
    end
  end

  # UX-11b: no outward actions, state, minimum strength or cap.
  def test_the_body_is_the_owner_contract_without_what_stays_the_owner
    assert_equal "CreateTaskRequest", request_component("create_task")
    shape = schemas.fetch("CreateTaskRequest")
    assert_equal false, shape["additionalProperties"]
    assert_equal %w[criteria title], shape.fetch("required").sort
    assert_equal %w[criteria details priority project_id title work_reference], shape.fetch("properties").keys.sort
    %w[actions state minimum_strength_rank budget_cap].each { |field| refute shape["properties"].key?(field), field }
    assert_equal 1, shape.dig("properties", "criteria", "minItems")
    assert_equal 24_002, shape.dig("properties", "details", "maxLength")
    good = { "title" => "made-up", "criteria" => [ { "text" => "made-up", "kind" => "review" } ] }
    assert validator("CreateTaskRequest").valid?(good)
    refute validator("CreateTaskRequest").valid?(good.merge("actions" => [])), "actions are the owner's"
    refute validator("CreateTaskRequest").valid?(good.merge("criteria" => [])), "a contract has criteria"
  end

  def test_the_answer_names_the_task_and_where_it_stands
    shape = schemas.fetch("AgentTaskCreated")
    assert_equal %w[state task_id], shape.fetch("required").sort
    assert_equal %w[backlog ready], shape.dig("properties", "state", "enum").sort
    response = operation("create_task").dig("responses", "200", "content", "application/json", "schema", "$ref")
    assert_equal "#/components/schemas/AgentTaskCreatedCompleted", response
    envelope = { "key" => "k", "command" => "add_task", "outcome" => "completed", "refusal" => nil }
    result = { "task_id" => "00000000-0000-4000-8000-000000000001", "state" => "backlog" }
    assert validator("AgentTaskCreatedCompleted").valid?(envelope.merge("result" => result))
    refute validator("AgentTaskCreatedCompleted").valid?(envelope.merge("result" => result.merge("state" => "working")))
  end

  # UX-14: one refusal for the three limits, after duplicate_name.
  def test_add_task_limit_is_a_listed_refusal_after_duplicate_name
    entry = registry["refusals"].find { |refusal| refusal["code"] == "add_task_limit" }
    refute_nil entry, "no refusal add_task_limit"
    assert_equal [ 14, false, false ], entry.values_at("precedence", "claims_only", "owner_only")
    assert_includes schemas.dig("Refusal", "properties", "code", "enum"), "add_task_limit"
  end

  # UX-13: the creator adds and completes, only in the call that adds.
  def test_the_creator_asks_for_add_task_and_complete_contract
    rows("add_task").each { |row| assert_equal %w[owner creator], row["who"] }
    rows("complete_contract").each { |row| assert_equal %w[owner planner creator], row["who"] }
    group = sm.fetch("groups").find { |entry| entry["id"] == "complete_contract" }
    assert_includes group["rows"].first["note"], "creator: only in the call that adds the task (create_task)"
  end

  # UX-16 and UX-14: two new Needs you items.
  def test_two_needs_you_items_tell_the_owner_of_agent_tasks
    assert_includes registry["needs_you_items"], "agent_task_incomplete"
    assert_includes registry["needs_you_items"], "agent_tasks_at_limit"
    payload = Leverage::Contract.payload_schema("inbox.opened", 1)
    assert_includes JSON.generate(payload), "agent_task_incomplete"
    assert_includes JSON.generate(payload), "agent_tasks_at_limit"
  end

  # UX-9: a seat reports its own model and effort.
  def test_report_model_runs_change_seat_as_the_seat
    entry = registry_operation("report_model")
    refute_nil entry, "report_model is not a registry operation"
    assert_equal [ "POST", "/v1/seat/model", "any", %w[change_seat], "agent" ],
      entry.values_at("method", "path", "caller", "commands", "tag")
    assert_equal "ReportModelRequest", request_component("report_model")
    shape = schemas.fetch("ReportModelRequest")
    assert_equal false, shape["additionalProperties"]
    assert_equal %w[effort model], shape.fetch("required").sort
    assert validator("ReportModelRequest").valid?({ "model" => nil, "effort" => nil })
    refute validator("ReportModelRequest").valid?({ "model" => "" , "effort" => nil }), "an empty name is null"
    refute validator("ReportModelRequest").valid?({ "model" => "made-up" }), "both keys are required"
    rows("change_seat").each { |row| assert_equal %w[owner self], row["who"] }
  end

  def test_the_join_instructions_carry_the_permissions_and_the_models
    shape = schemas.fetch("JoinInstructions")
    assert_equal "#/components/schemas/SeatPermissions", shape.dig("properties", "permissions", "$ref")
    assert_includes shape.fetch("required"), "permissions"
    assert shape.fetch("properties").key?("models")
    shape.fetch("examples").each { |example| assert validator("JoinInstructions").valid?(example) }
  end

  def test_trace_25_adds_tasks_as_a_seat
    trace = Leverage::Contract.trace("25-agent-adds-task")
    commands = trace.fetch("commands")
    creates = commands.select { |command| command["operation_id"] == "create_task" }
    assert_operator creates.size, :>=, 2
    events = commands.flat_map { |command| command.dig("expect", "events") || [] }
    created = events.select { |event| event["type"] == "task.created" }
    assert(created.all? { |event| event["actor_kind"] == "seat" }, "the seat adds every task")
    assert(events.any? { |event| event["type"] == "inbox.opened" && event.dig("payload", "item") == "agent_task_incomplete" })
  end
end
