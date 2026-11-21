require "test_helper"
require_relative "../support/http_calls"

class QuestionsApprovalsOwnerTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  CONTRACT = {
    "title" => "Made-up work", "goal" => "Make one example.", "details" => "Use a made-up example.",
    "criteria" => [ { "kind" => "build", "text" => "Make the example." },
                    { "kind" => "review", "text" => "Review the example." } ],
    "actions" => [], "budget_cap" => nil, "minimum_strength_rank" => nil, "work_reference" => nil
  }.freeze

  setup { @scenario = Scenario.new }

  test "a project pauses at its budget and raising the budget resumes every task" do
    shipped_rule("project_budget_pause")
    builder, other = Array.new(2) { @scenario.seat }
    start_audit
    send_command("create_project", body: { "name" => "Made-up project", "budget" => 1 })
    project = Project.where(workspace_id: @scenario.workspace_id).sole
    first = create_task(project: project)
    claim(builder, first)
    second = create_task(project: project)
    start = @scenario.workspace.reload.last_seq

    [ 0.6, 0.5 ].each { |spend| report_cost(builder, first, spend) }
    shown = read("list_projects").fetch("projects").sole
    assert_equal [ 1.1, true ], shown.values_at("spent", "paused")
    assert_equal %w[project_paused], open_holds(first)
    assert_equal %w[project_paused], open_holds(second)
    item = read("list_inbox").fetch("items").sole
    assert_equal [ "project_budget_reached", project.id, %w[change_budget resume_project] ],
      item.values_at("kind", "about_id", "choices")
    assert_refused "not_eligible", "claim_next_task", caller: other
    assert_equal %w[cost.reported cost.reported check.finished project.paused hold.opened hold.opened inbox.opened],
      events_after(start).pluck(:type)

    third = create_task(project: project, ready: false)
    assert_equal %w[task.created hold.opened], Event.where(task_id: third.id).order(:seq).pluck(:type)
    send_command("change_budget", ids: path(project), body: { "budget" => 5 })
    assert_equal [ [], [], [] ], [ open_holds(first), open_holds(second), open_holds(third) ]
    assert_empty read("list_inbox").fetch("items")
    assert_equal [ "resume", first.id ], read("get_next", caller: builder).values_at("kind", "id")
    assert_equal [ 1.1, false, 5 ], read("list_projects").fetch("projects").sole.values_at("spent", "paused", "budget")
    assert_log_consistent
  end

  test "editing a contract to raise its cap closes its budget hold after recording the change" do
    shipped_rule("project_budget_pause")
    builder = @scenario.seat
    start_audit
    task = create_task(contract: CONTRACT.merge("budget_cap" => 1))
    claim(builder, task)
    report_cost(builder, task, 1)
    assert_equal %w[budget], open_holds(task)
    assert_equal "task_budget_reached", read("list_inbox").fetch("items").sole.fetch("kind")

    key = new_key("raise-cap-in-contract")
    send_command("edit_contract", ids: path(task), body: CONTRACT.merge("budget_cap" => 5), key: key)
    types = Event.where(workspace_id: @scenario.workspace_id, command_id: key).order(:seq).pluck(:type)
    assert_equal %w[task.contract_changed hold.closed inbox.resolved],
      types.select { |type| %w[task.contract_changed hold.closed inbox.resolved].include?(type) }
    assert_equal 5, read("get_task", ids: path(task)).dig("task", "budget_cap")
    assert_empty open_holds(task)
    assert_log_consistent
  end

  test "two failed reviews escalate and the stronger builder cannot hand off to another provider's rank-one login" do
    shipped_rule("escalate_after_failed_reviews")
    regular = @scenario.seat
    primary = @scenario.credential(provider: "claude", strength_rank: 1)
    @scenario.credential(provider: "codex", strength_rank: 1)
    stronger = @scenario.seat(credential: primary, strength_rank: 2)
    reviewer = @scenario.seat(role: "reviewer", provider: "gemini")
    start_audit
    task = create_task
    claim(regular, task)
    2.times { fail_round(task, regular, reviewer) }

    assert_equal [ "ready", 2, nil ], read("get_task", ids: path(task)).fetch("task")
      .values_at("state", "minimum_strength_rank", "holder_seat_id")
    assert_equal 1, Event.where(task_id: task.id, type: "task.reassigned").count
    assert_refused "not_eligible", "claim_next_task", caller: regular
    claim(stronger, task)
    assert_equal primary.id, task.reload.credential_id
    send_command("report_limit", token: @scenario.helper_token, ids: path(primary), body: {
      "credential_id" => primary.id, "seat_id" => stronger.id, "task_id" => task.id,
      "review_id" => nil, "job_id" => nil, "window" => "five_hour", "reset_at" => nil,
      "observed_at" => @scenario.database_now.iso8601(6), "tool_version" => "0.0.0-example"
    })
    assert_equal %w[credential_limit], open_holds(task)
    assert_equal [ primary.id, stronger.id ], task.reload.values_at(:credential_id, :holder_seat_id)
    assert_empty Event.where(task_id: task.id, type: "credential.switched")
    assert_log_consistent
  end

  test "task and project deletion refuse active work and keep the terminal task's history" do
    send_command("create_project", body: { "name" => "Made-up project" })
    project = Project.where(workspace_id: @scenario.workspace_id).sole
    task = create_task(project: project)
    %w[delete_task_content delete_project_content].zip([ task, project ]).each do |operation, record|
      assert_refused "invalid_state", operation, ids: path(record)
    end

    send_command("cancel_task", ids: path(task))
    send_command("delete_task_content", ids: path(task))
    assert_equal [ "cancelled", "", "", nil ], read("get_task", ids: path(task)).fetch("task")
      .values_at("state", "title", "goal", "details")
    assert_refused "invalid_state", "delete_task_content", ids: path(task)
    send_command("delete_project_content", ids: path(project))
    assert_refused "invalid_state", "delete_project_content", ids: path(project)
    assert_equal 1, Event.where(task_id: task.id, type: "content.deleted").count
    assert_equal 1, Event.where(project_id: project.id, task_id: nil, type: "content.deleted").count
    assert_log_consistent
  end

  test "a task page keeps its criterion but omits evidence after deleting the evidence contents" do
    task = create_task
    builder = @scenario.seat
    start_audit
    claim(builder, task)
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    ids = path(task).merge("cid" => criterion.id)
    send_command("start_criterion", caller: builder, ids: ids)
    send_command("pass_criterion", caller: builder, ids: ids,
      body: { "evidence" => { "kind" => "note", "value" => "Made-up evidence." } })
    assert_equal 1, read("get_task", ids: path(task)).fetch("criteria").find { |row| row["id"] == criterion.id }.fetch("evidence").size

    send_command("cancel_task", ids: path(task))
    send_command("delete_task_content", ids: path(task))

    row = read("get_task", ids: path(task)).fetch("criteria").find { |entry| entry["id"] == criterion.id }
    assert_equal "passed", row.fetch("state")
    assert_empty row.fetch("evidence")
    assert_log_consistent
  end

  test "money outside the persisted range is invalid before a project or task is changed" do
    project = @scenario.project(budget: 25)
    task = create_task
    cases = [
      [ "create_project", {}, { "name" => "Made-up project", "budget" => 1_000_000_000 } ],
      [ "change_budget", path(project), { "budget" => 1_000_000_000 } ],
      [ "change_task_cap", path(task), { "budget_cap" => 99_999_999.9999999 } ]
    ]
    cases.each do |operation, ids, body|
      call(operation, token: auth(nil), ids: ids, key: new_key, body: body, check_request: false)
      assert_equal 422, response.status, operation
      assert_equal "invalid", response.parsed_body.dig("error", "code")
      assert_response_matches_contract
    end
    assert_equal 25, project.reload.budget
    assert_nil task.reload.budget_cap
  end

  test "the workspace settings read and a newly granted lease use the saved length" do
    builder = @scenario.seat
    start_audit
    before = read("get_workspace_settings")
    length = 900
    settings = before.merge("lease_length_seconds" => length, "recovery_time_ceiling_seconds" => 300)
    saved = send_command("change_workspace_settings", body: settings).fetch("result")
    assert_equal settings, saved
    assert_equal settings, read("get_workspace_settings")

    task = create_task
    claim(builder, task)
    granted = Event.find_by!(task_id: task.id, type: "task.claimed")
    assert_in_delta length, task.reload.lease_due_at - granted.at, 0.000001
    send_command("change_workspace_settings", body: { "recovery_time_ceiling_seconds" => nil })
    assert_equal settings.merge("recovery_time_ceiling_seconds" => nil), read("get_workspace_settings")
    assert_log_consistent
  end

  test "the planner's empty actions list preserves the owner's ordered outward actions" do
    planner = @scenario.planner
    start_audit
    definitions = [ { "kind" => "publish", "description" => "Make-believe publication." },
                    { "kind" => "send", "description" => "Make-believe delivery." } ]
    task = create_task(ready: false, actions: definitions)
    original = read("get_task", ids: path(task)).fetch("actions")
    send_command("draft_contract", ids: path(task))
    job = send_command("claim_next_job", caller: planner).fetch("result")
    assert_equal "contract_draft", job.fetch("kind")
    send_command("submit_job_result", caller: planner, ids: { "id" => job.fetch("job_id") },
      body: { "result" => CONTRACT, "tokens" => 0, "spend" => 0 })
    assert_equal "ready", task.reload.state
    expected = original.map { |row| row.values_at("id", "kind", "position") }
    assert_equal 2, expected.size
    assert_equal expected, read("get_task", ids: path(task)).fetch("actions").map { |row| row.values_at("id", "kind", "position") }
    assert_log_consistent
  end

  test "owner reads carry an access request description outside the event facts" do
    builder = @scenario.seat
    start_audit
    task = create_task
    claim(builder, task)
    description = "Made-up access request detail."
    send_command("request_access", ids: path(task), caller: builder, body: { "description" => description })
    item = read("list_inbox").fetch("items").sole
    assert_equal "access_request", item.fetch("kind")
    assert item["detail"] == description, "the inbox shows the access request description"
    task_item = read("get_task", ids: path(task)).fetch("inbox_items").sole
    assert task_item["detail"] == description, "the task page shows the same description"
    refute item.fetch("facts").to_json.include?(description)
    refute Event.where(task_id: task.id).pluck(:payload).to_json.include?(description)
    send_command("grant_access", ids: path(task))
    assert_empty read("list_inbox").fetch("items")
    assert_log_consistent
  end

  test "an owner can add and save a gate for outward actions in each of the new scopes" do
    send_command("create_project", body: { "name" => "Made-up project" })
    project = Project.where(workspace_id: @scenario.workspace_id).sole
    name = "Check the made-up action"
    instruction = "Check the action against the example."
    send_command("add_rule", body: {
      "name" => name, "instruction" => instruction, "hook" => "action.requested",
      "scope" => { "kind" => "named_projects", "project_ids" => [ project.id ], "action_kinds" => [] }
    })
    rule = Rule.where(workspace_id: @scenario.workspace_id).sole
    shown = read("list_rules").fetch("rules").sole.fetch("version")
    assert_equal [ "action.requested", "named_projects", [ project.id ] ],
      [ shown.fetch("hook"), shown.dig("scope", "kind"), shown.dig("scope", "project_ids") ]

    send_command("save_rule", ids: path(rule), body: {
      "name" => name, "instruction" => instruction, "parameters" => nil, "on_fail" => "block", "route" => "owner",
      "queue_timeout_seconds" => nil, "run_timeout_seconds" => nil,
      "scope" => { "kind" => "action_kinds", "project_ids" => [], "action_kinds" => [ "publish" ] }
    })
    saved = read("list_rules").fetch("rules").sole.fetch("version")
    assert_equal [ "action.requested", "action_kinds", [ "publish" ] ],
      [ saved.fetch("hook"), saved.dig("scope", "kind"), saved.dig("scope", "action_kinds") ]
    assert_log_consistent
  end

  test "the HTTP builder landing prompt explains answer and action offers" do
    builder = @scenario.seat
    landing = read("get_landing_prompt", ids: path(builder), query: { "connection" => "http" })
    assert_equal "http", landing.fetch("connection")
    assert_match(/^[-] `answer`: .+`get_question`/, landing.fetch("text"))
    assert_match(/^[-] `action`: .+`start_action`/, landing.fetch("text"))
  end

  private

  def assert_valid(pointer, body, what)
    errors = openapi_schemer.ref(pointer).validate(body).map { |error| error.values_at("data_pointer", "type") }
    assert_empty errors, "#{what} does not match the contract (#{pointer})"
  end

  def path(record) = { "id" => record.id }

  def events_after(seq) = Event.where(workspace_id: @scenario.workspace_id).where("seq > ?", seq).order(:seq)

  def open_holds(task) = Hold.where(task_id: task.id, closed_at: nil).order(:opened_at).pluck(:reason)

  def shipped_rule(key) = @scenario.rule(key: key, origin: "shipped")

  def auth(caller) = caller ? @scenario.token_for(caller) : @scenario.owner_token

  def send_command(operation, caller: nil, token: auth(caller), ids: {}, body: nil, status: 200, key: new_key)
    call(operation, token: token, key: key, ids: ids, body: body)
    assert_equal status, response.status, operation
    assert_response_matches_contract
    response.parsed_body
  end

  def assert_refused(code, operation, **options)
    answer = send_command(operation, status: 409, **options)
    assert_equal [ "refused", code ], [ answer.fetch("outcome"), answer.dig("refusal", "code") ]
  end

  def read(operation, caller: nil, ids: {}, query: nil)
    call(operation, token: auth(caller), ids: ids, query: query)
    assert_equal 200, response.status, operation
    assert_response_matches_contract
    response.parsed_body
  end

  def create_task(project: nil, contract: CONTRACT, ready: true, actions: [])
    key = new_key("add-task")
    send_command("add_task", key: key,
      body: contract.slice("title", "goal", "details").merge("project_id" => project&.id, "actions" => actions))
    created = Event.find_by!(workspace_id: @scenario.workspace_id, command_id: key, type: "task.created")
    task = Task.find(created.task_id)
    send_command("complete_contract", ids: path(task), body: contract) if ready
    task
  end

  def claim(builder, task)
    result = send_command("claim_next_task", caller: builder).fetch("result")
    assert_equal task.id, result.dig("task", "id")
    acknowledge(builder, task, "task")
  end

  def acknowledge(seat, record, type)
    briefing = read("get_#{type}_briefing", caller: seat, ids: path(record)).fetch("briefing")
    send_command("acknowledge_#{type}_briefing", caller: seat, ids: path(record),
      body: { "briefing_hash" => briefing.fetch("hash") })
  end

  def report_cost(builder, task, spend)
    send_command("report_cost", caller: builder, ids: path(task), body: { "tokens" => 50, "spend" => spend })
  end

  def fail_round(task, builder, reviewer)
    acknowledge(builder, task, "task")
    criterion = Criterion.where(task_id: task.id, kind: "build", removed_at: nil).sole
    send_command("pass_criterion", caller: builder, ids: path(task).merge("cid" => criterion.id),
      body: { "evidence" => { "kind" => "note", "value" => "Made-up evidence." } })
    send_command("submit_task", caller: builder, ids: path(task),
      body: { "handoff_note" => "Made-up handoff.", "work_reference" => nil })
    send_command("claim_next_review", caller: reviewer)
    review = Review.where(task_id: task.id, verdict: nil).sole
    acknowledge(reviewer, review, "review")
    send_command("give_verdict", caller: reviewer, ids: path(review), body: {
      "verdict" => "failed", "failed_criteria" => [ criterion.id ], "notes" => "Made-up review.",
      "tokens" => 0, "spend" => 0
    })
  end

  def start_audit = @audit_from = @scenario.workspace.reload.last_seq

  def assert_log_consistent
    assert_empty Leverage::Replay.diff(@scenario.workspace_id), "replay"
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: @audit_from || 0), "log audit"
  end
end
