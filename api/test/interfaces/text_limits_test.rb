require "test_helper"
require_relative "../support/http_calls"

# Task text has a length limit (milestone 4 review, finding 9): a checker
# gets the task text as one argument of its tool, and an argument over the
# Mac's limit stops the tool from starting at all, which would force the
# check into error. The contract therefore puts a maxLength on each
# task-text field and a maxItems on each list of them, and the server
# refuses a longer body with 422 invalid before anything is written or any
# check is queued. Every value is made up.
class TextLimitsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  setup do
    @scenario = Scenario.new
    @owner_token = @scenario.owner_token
    @scenario.rule(hook: "task.before_ready", name: "Made-up rule at ready")
  end

  def schema(name) = Leverage::Contract.openapi.dig("components", "schemas", name)

  def limit(name, property) = schema(name).dig("properties", property, "maxLength")

  def contract_body(**overrides)
    { "title" => "A made-up task", "details" => "A made-up goal.\n\nMade-up details.",
      "criteria" => [ { "text" => "Made-up build criterion.", "kind" => "build" },
                      { "text" => "A reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }.merge(overrides)
  end

  def complete(task, body)
    call("complete_contract", token: @owner_token, key: new_key, ids: { "id" => task.id }, body: body, check_request: false)
  end

  def assert_refused_before_anything(task)
    assert_response :unprocessable_entity
    assert_equal "invalid", response.parsed_body.dig("error", "code") || response.parsed_body["code"]
    assert_equal "backlog", task.reload.state
    assert_empty RuleCheck.where(workspace_id: @scenario.workspace_id, task_id: task.id)
    assert_empty Job.where(workspace_id: @scenario.workspace_id, task_id: task.id)
  end

  test "every task-text field of the requests has a limit, and every list of them a count" do
    { "CompleteContractRequest" => %w[title details work_reference], "AddTaskRequest" => %w[title details work_reference],
      "SubmitTaskRequest" => %w[handoff_note work_reference], "GiveVerdictRequest" => %w[notes],
      "OverrideCheckRequest" => %w[reason], "AddRuleRequest" => %w[name instruction],
      "SaveRuleRequest" => %w[name instruction], "CriterionInput" => %w[text], "ActionInput" => %w[description] }
      .each do |name, properties|
        properties.each { |property| assert_kind_of Integer, limit(name, property), "#{name}.#{property}" }
      end
    assert_kind_of Integer, schema("PassCriterionRequest").dig("properties", "evidence", "properties", "value", "maxLength")
    %w[CompleteContractRequest AddTaskRequest].each do |name|
      %w[criteria actions].each do |list|
        assert_kind_of Integer, schema(name).dig("properties", list, "maxItems"), "#{name}.#{list}"
      end
    end
  end

  test "a contract with details one character over the limit is 422 invalid, and no check is queued" do
    task = @scenario.task(state: "backlog", criteria: [])

    complete(task, contract_body("details" => "d" * (limit("CompleteContractRequest", "details") + 1)))

    assert_refused_before_anything(task)
  end

  test "a criterion over its limit, or one criterion too many, is 422 invalid" do
    task = @scenario.task(state: "backlog", criteria: [])
    long = { "text" => "c" * (limit("CriterionInput", "text") + 1), "kind" => "build" }
    complete(task, contract_body("criteria" => [ long, { "text" => "A reviewer agrees.", "kind" => "review" } ]))
    assert_refused_before_anything(task)

    count = schema("CompleteContractRequest").dig("properties", "criteria", "maxItems") + 1
    complete(task, contract_body("criteria" => Array.new(count) { |index| { "text" => "Made-up #{index}.", "kind" => "build" } }))
    assert_refused_before_anything(task)
  end

  test "a contract with details at the limit is accepted and waits on its check" do
    task = @scenario.task(state: "backlog", criteria: [])

    complete(task, contract_body("details" => "d" * limit("CompleteContractRequest", "details")))

    assert_response :accepted
    assert_equal 1, RuleCheck.where(workspace_id: @scenario.workspace_id, task_id: task.id).count
  end

  test "a handoff note over its limit is 422 invalid" do
    builder = @scenario.seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder)

    call("submit_task", token: @scenario.token_for(builder), key: new_key, ids: { "id" => task.id },
      body: { "handoff_note" => "n" * (limit("SubmitTaskRequest", "handoff_note") + 1), "work_reference" => nil },
      check_request: false)

    assert_response :unprocessable_entity
    assert_equal "working", task.reload.state
  end
end
