require "test_helper"
require_relative "../support/http_calls"

class PromptConnectedAgentsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  CONTRACT = {
    "title" => "Make a sample", "details" => "Produce one sample.\n\nUse made-up numbers.",
    "criteria" => [ { "kind" => "build", "text" => "Produce the sample." },
                    { "kind" => "review", "text" => "Verify the sample." } ],
    "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil
  }.freeze

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner_token
  end

  test "two prompt-connected General seats finish work and removal gives held work back" do
    first, first_token = connect("Made-up first seat", "claude")
    _second, second_token = connect("Made-up second seat", "codex")
    assert_equal "none", next_item(first_token).fetch("kind")

    task = ready_task
    assert_equal "task", next_item(first_token).fetch("kind")
    build(task, first_token)

    assert_equal "review", next_item(second_token).fetch("kind")
    review(task, second_token)
    assert_equal "done", Task.find(task).state

    next_task = ready_task
    assert_equal "task", next_item(first_token).fetch("kind")
    assert_equal next_task, change("claim_next_task", token: first_token).dig("result", "task", "id")

    refused = change("issue_landing_prompt", id: first, body: { "connection" => "mcp" }, status: :conflict)
    assert_equal "invalid_state", refused.dig("refusal", "code")
    assert_equal [ "working", first ], Task.find(next_task).values_at(:state, :holder_seat_id)

    change("remove_seat", id: first)
    call("get_next", token: first_token, query: { "wait" => 0 })
    assert_response :unauthorized
    assert_response_matches_contract
    assert_equal [ "ready", nil ], Task.find(next_task).values_at(:state, :holder_seat_id)
    assert_equal "seat_removed", Event.find_by!(task_id: next_task, type: "task.released").payload.fetch("reason")
    assert_equal next_task, change("claim_next_task", token: second_token).dig("result", "task", "id")
  end

  test "a landing prompt refusal leaves the held check job and session active" do
    seat, token = connect("Made-up check seat", "codex")
    next_item(token)
    @scenario.rule(key: "specific_details", origin: "shipped")
    task = add_task
    change("complete_contract", id: task, body: CONTRACT, status: :accepted)
    job = claim_check(token)

    refused = change("issue_landing_prompt", id: seat, body: { "connection" => "http" }, status: :conflict)

    assert_equal "invalid_state", refused.dig("refusal", "code")
    assert_equal [ "claimed", seat, 1 ], Job.find(job).attributes.values_at("state", "claimed_by_seat_id", "attempt_number")
    assert_equal "job", next_item(token).fetch("kind")
    assert_empty Job.where(task_id: task, state: "queued")
  end

  private

  def connect(name, provider)
    receipt = change("connect_seat", body: { "name" => name, "role" => "general", "provider" => provider }).fetch("result")
    assert_equal [ "seat_id" ], receipt.keys
    seat = receipt.fetch("seat_id")
    token = issue(seat)
    join = read("get_join", token: token)
    assert_equal [ "general", "http" ], join.values_at("role", "connection")
    [ seat, token ]
  end

  def issue(seat, connection: "http")
    change("issue_landing_prompt", id: seat, body: { "connection" => connection }).dig("result", "seat_token")
  end

  def next_item(token)
    read("get_next", token: token, query: { "wait" => 0 })
  end

  def add_task
    change("add_task", body: CONTRACT.slice("title", "details", "actions")).dig("result", "task_id")
  end

  def ready_task
    task = add_task
    change("complete_contract", id: task, body: CONTRACT)
    task
  end

  def build(task, token)
    receipt = change("claim_next_task", token: token)
    assert_equal task, receipt.dig("result", "task", "id")
    acknowledge("task", task, token)
    criterion = Criterion.find_by!(task_id: task, kind: "build").id
    change("start_criterion", id: task, ids: { "cid" => criterion }, token: token)
    change("pass_criterion", id: task, ids: { "cid" => criterion }, token: token,
      body: { "evidence" => { "kind" => "note", "value" => "The sample is present." } })
    change("submit_task", id: task, token: token, body: { "handoff_note" => "Sample ready.", "work_reference" => nil })
  end

  def review(task, token)
    receipt = change("claim_next_review", token: token)
    assert_equal task, receipt.dig("result", "review", "task_id")
    review = receipt.dig("result", "review", "id")
    acknowledge("review", review, token)
    change("give_verdict", id: review, token: token,
      body: { "verdict" => "passed", "notes" => "The sample matches.", "failed_criteria" => [], "tokens" => 0, "spend" => 0 })
  end

  def acknowledge(kind, id, token)
    briefing = read("get_#{kind}_briefing", id: id, token: token).fetch("briefing")
    change("acknowledge_#{kind}_briefing", id: id, token: token, body: { "briefing_hash" => briefing.fetch("hash") })
  end

  def claim_check(token)
    assert_equal "job", next_item(token).fetch("kind")
    receipt = change("claim_next_job", token: token).fetch("result")
    assert_equal "rule_check", receipt.fetch("kind")
    receipt.fetch("job_id")
  end

  def change(operation, token: @owner, id: nil, body: nil, ids: {}, status: :ok)
    paths = id ? ids.merge("id" => id) : ids
    call(operation, token: token, key: new_key, ids: paths, body: body)
    assert_response status, operation
    assert_response_matches_contract
    response.parsed_body
  end

  def read(operation, token:, id: nil, query: nil)
    call(operation, token: token, ids: (id ? { "id" => id } : {}), query: query)
    assert_response :ok, operation
    assert_response_matches_contract
    response.parsed_body
  end
end
