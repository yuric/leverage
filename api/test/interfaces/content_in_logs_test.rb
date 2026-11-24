require "test_helper"

# Task text, a rule's name and instruction, a checker's reason, an override
# reason, notes and evidence are content (PRD, Privacy: event payloads hold
# no content; content lives in its own tables). The server's log is not one
# of them: the request log's "Parameters:" line keeps each parameter's key,
# and its value only when the value is an id (milestone 4 plan RT-8, whose
# end-to-end scan looks for a test's marker words in every log line).
class ContentInLogsTest < ActionDispatch::IntegrationTest
  MARKER = "zqmarker#{SecureRandom.hex(4)}".freeze
  ID = "00000000-0000-4000-8000-0000000000e1".freeze

  def filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

  def schemas = Leverage::Contract.openapi.dig("components", "schemas")

  # A body for a request schema with the marker in every string, an id in
  # every uuid, and one element in every array: whatever a client may send.
  def body_for(schema, depth = 0)
    schema = schemas.fetch(schema["$ref"].split("/").last) if schema["$ref"]
    return MARKER if depth > 8
    options = schema["oneOf"] || schema["anyOf"]
    return body_for(options.find { |option| option["type"] != "null" } || options.first, depth + 1) if options
    type = Array(schema["type"]).find { |kind| kind != "null" }
    case type
    when "object", nil
      (schema["properties"] || {}).to_h { |name, property| [ name, body_for(property, depth + 1) ] }
    when "array" then [ body_for(schema["items"] || {}, depth + 1) ]
    when "string" then schema["format"] == "uuid" ? ID : MARKER
    when "integer", "number" then 1
    when "boolean" then true
    else MARKER
    end
  end

  def request_schemas
    Leverage::Contract.openapi["paths"].flat_map do |path, methods|
      methods.filter_map do |verb, operation|
        schema = operation.is_a?(Hash) && operation.dig("requestBody", "content", "application/json", "schema")
        [ "#{verb.upcase} #{path}", schema ] if schema
      end
    end
  end

  test "no request body's text reaches the log; its ids do" do
    cases = request_schemas
    assert_operator cases.size, :>=, 40
    cases.each do |name, schema|
      body = body_for(schema)
      text = JSON.generate(body)
      next unless text.include?(MARKER)

      filtered = JSON.generate(filter.filter(body.merge("id" => ID)))
      assert_not_includes filtered, MARKER, name
      assert_includes filtered, ID, "#{name}: an id stays"
    end
  end

  test "the request log of a task's add and its contract holds none of its text" do
    scenario = Scenario.new
    headers = { "Authorization" => "Bearer #{scenario.owner_token}", "Content-Type" => "application/json" }
    io = StringIO.new
    capture = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(capture)
    begin
      post "/v1/owner/tasks", params: { title: "Title #{MARKER}", details: "Goal #{MARKER}" }.to_json,
        headers: headers.merge("Idempotency-Key" => "key-#{SecureRandom.hex(6)}")
      assert_response :success
      task = response.parsed_body.dig("result", "task_id")
      contract = { title: "Title #{MARKER}", details: "Goal #{MARKER}\n\nDetails #{MARKER}",
                   criteria: [ { text: "Criterion #{MARKER}", kind: "build" },
                               { text: "An independent reviewer agrees.", kind: "review" } ], actions: [],
                   minimum_strength_rank: nil, budget_cap: nil, work_reference: nil }
      post "/v1/owner/tasks/#{task}/complete-contract", params: contract.to_json,
        headers: headers.merge("Idempotency-Key" => "key-#{SecureRandom.hex(6)}")
      assert_response :success
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
    log = io.string
    assert_match(/leverage\.command command=complete_contract /, log, "the log was captured")
    assert_match(/Parameters: .*"details" => "\[FILTERED\]"/, log)
    assert_includes log, task, "the task's id is kept"
    assert_not_includes log, MARKER
  end
end
