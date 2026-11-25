require "test_helper"
require_relative "../support/http_calls"

# Task text has a length limit (milestone 4 review, finding 9): a checker
# gets the task text as one argument of its tool, and an argument over the
# Mac's limit stops the tool from starting at all, which would force the
# check into error. The contract therefore puts a maxLength on each
# task-text field and a maxItems on each list of them, and the server
# refuses a longer body with 422 invalid before anything is written or any
# check is queued. The text a question, an access request, an answer, a
# project and its brief carry has limits for the same reason: a question
# job's material quotes the question, its assumption, the earlier answers
# and the brief. Every value is made up.
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

  # The text a seat that holds a task sends about it, and the owner's
  # text that is quoted into a job's material with it.
  LATER_TEXT = { "AskQuestionRequest" => %w[text assumption], "RequestAccessRequest" => %w[description],
                 "AnswerQuestionRequest" => %w[answer], "CreateProjectRequest" => %w[name goal] }.freeze

  test "the text of a question, an access request, an answer and a project has a limit, and a brief a count" do
    LATER_TEXT.each do |name, properties|
      properties.each { |property| assert_kind_of Integer, limit(name, property), "#{name}.#{property}" }
    end
    entries = schema("EditBriefRequest").dig("properties", "entries")
    assert_kind_of Integer, entries.fetch("maxItems")
    assert_kind_of Integer, entries.dig("items", "properties", "text", "maxLength")
  end

  def working_task
    builder = @scenario.seat(role: "builder")
    [ @scenario.task(state: "working", builder: builder), @scenario.token_for(builder) ]
  end

  def question_body(**overrides)
    { "text" => "Which made-up sample?", "assumption" => "The first made-up sample.", "blocking" => true }.merge(overrides)
  end

  def assert_invalid
    assert_response :unprocessable_entity
    assert_equal "invalid", response.parsed_body.dig("error", "code")
  end

  test "a question or an assumption one character over its limit is 422 invalid and nothing is written" do
    task, token = working_task
    counts = -> { [ Question.count, Job.count, RuleCheck.count, Event.count ] }
    before = counts.call

    %w[text assumption].each do |field|
      body = question_body(field => "q" * (limit("AskQuestionRequest", field) + 1))
      call("ask_question", token: token, key: new_key, ids: { "id" => task.id }, body: body, check_request: false)

      assert_invalid
      assert_equal before, counts.call, field
    end
  end

  test "a question and an assumption at their limits are accepted" do
    task, token = working_task
    briefing = call("get_task_briefing", token: token, ids: { "id" => task.id }).parsed_body.fetch("briefing")
    call("acknowledge_task_briefing", token: token, key: new_key, ids: { "id" => task.id },
      body: { "briefing_hash" => briefing.fetch("hash") })
    body = question_body("text" => "q" * limit("AskQuestionRequest", "text"),
      "assumption" => "a" * limit("AskQuestionRequest", "assumption"))

    call("ask_question", token: token, key: new_key, ids: { "id" => task.id }, body: body)

    assert_response :ok
    assert_equal body.fetch("text"), Question.find_by!(task_id: task.id).text
  end

  test "an access request over its limit is 422 invalid and opens no hold; one at the limit is accepted" do
    task, token = working_task
    holds = Hold.where(task_id: task.id)
    size = limit("RequestAccessRequest", "description")

    call("request_access", token: token, key: new_key, ids: { "id" => task.id },
      body: { "description" => "d" * (size + 1) }, check_request: false)
    assert_invalid
    assert_empty holds.reload

    call("request_access", token: token, key: new_key, ids: { "id" => task.id }, body: { "description" => "d" * size })
    assert_response :ok
    assert_equal [ size ], holds.reload.map { |hold| hold.detail.length }
  end

  test "an answer over its limit is 422 invalid and leaves the question open" do
    task, = working_task
    question = @scenario.question(task)

    call("answer_question", token: @owner_token, key: new_key, ids: { "id" => question.id },
      body: { "answer" => "a" * (limit("AnswerQuestionRequest", "answer") + 1) }, check_request: false)

    assert_invalid
    assert_equal "open", question.reload.outcome
  end

  test "a project name or goal over its limit is 422 invalid and makes no project" do
    projects = Project.where(workspace_id: @scenario.workspace_id)
    before = projects.count

    %w[name goal].each do |field|
      body = { "name" => "Made-up project", "goal" => "A made-up goal." }
        .merge(field => "p" * (limit("CreateProjectRequest", field) + 1))
      call("create_project", token: @owner_token, key: new_key, body: body, check_request: false)

      assert_invalid
      assert_equal before, projects.count, field
    end
  end

  test "a brief entry over its limit, or one entry too many, is 422 invalid and the brief stays as it was" do
    project = @scenario.project
    entries = schema("EditBriefRequest").dig("properties", "entries")
    long = [ { "kind" => "rule", "text" => "b" * (entries.dig("items", "properties", "text", "maxLength") + 1) } ]
    many = Array.new(entries.fetch("maxItems") + 1) { |index| { "kind" => "lesson", "text" => "Made-up lesson #{index}." } }

    [ long, many ].each do |list|
      call("edit_brief", token: @owner_token, key: new_key, ids: { "id" => project.id }, body: { "entries" => list },
        check_request: false)

      assert_invalid
      assert_equal 0, project.reload.brief_version
      assert_empty BriefEntry.where(project_id: project.id)
    end

    call("edit_brief", token: @owner_token, key: new_key, ids: { "id" => project.id },
      body: { "entries" => many.first(entries.fetch("maxItems")) })
    assert_response :ok
    assert_equal 1, project.reload.brief_version
  end
end
