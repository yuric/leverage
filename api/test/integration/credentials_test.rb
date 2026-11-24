require "test_helper"
require_relative "../support/http_calls"

class CredentialsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner_token
  end

  test "an empty order completes only when the added set is empty" do
    key = new_key("empty-order")
    call("reorder_credentials", token: @owner, key: key, body: { "order" => [] }, check_request: false)
    assert_response :ok
    assert_response_matches_contract
    assert_equal "completed", response.parsed_body.fetch("outcome")
    assert_empty events(key)

    @scenario.credential
    key = new_key("incomplete-order")
    call("reorder_credentials", token: @owner, key: key, body: { "order" => [] }, check_request: false)
    assert_response :unprocessable_content
    assert_response_matches_contract
    assert_equal "invalid", response.parsed_body.dig("error", "code")
    assert_empty events(key)
    refute Command.exists?(workspace_id: @scenario.workspace_id, key: key)
  end

  test "an observation too far ahead is invalid and the owner sees the subsequent valid reading" do
    helper = complete("issue_helper_token", body: { "name" => "Made-up helper" }).fetch("helper_token")
    id = @scenario.credential.id
    now = @scenario.database_now.round(6)
    call("report_reading", token: helper, ids: id_path(id), key: new_key("ahead"),
      body: reading(id, observed_at: now + 2.minutes, percent_used: 99))
    assert_response :unprocessable_content
    assert_response_matches_contract
    assert_equal "invalid", response.parsed_body.dig("error", "code")

    valid = reading(id, observed_at: now, percent_used: 25)
    complete("report_reading", token: helper, ids: id_path(id), body: valid)
    assert_equal valid, list_credentials.sole.fetch("reading")
    assert_equal 1, CredentialReading.where(credential_id: id).count
  end

  test "credential changes go through all three interfaces and the log replays and passes its audit" do
    @helper = complete("issue_helper_token", body: { "name" => "Made-up helper" }).fetch("helper_token")
    spare = add_account("Spare login", "claude")
    token = add_account("Sample API account", "openai_api", kind: "api_token")
    login = add_account("Main login", "claude")
    assert_equal [ spare, login, token ], list_credentials.map { |row| row.dig("credential", "id") }
    assert_equal [ spare, login, token ], list_credentials.map { |row| row.dig("reading", "credential_id") }

    verify_all([ spare, login, token ])
    seat, seat_token = connect_builder(login)
    task = claim_task(seat_token, login, "Read to continue")
    wait_on_limit(seat, task, login)
    key = new_key("capacity")
    complete("report_reading", token: @helper, ids: id_path(login), key: key,
      body: reading(login, observed_at: Credential.find(login).limited_since + Rational(1, 1_000_000), percent_used: 40))
    assert_equal %w[hold.closed inbox.resolved], events(key).map(&:type)
    assert events(key).all? { |event| event.actor_id == Helper.find_by!(workspace_id: @scenario.workspace_id).id }
    assert_nil Credential.find(login).limited_since
    seat_token = start_run(login)
    complete("cancel_task", ids: id_path(task))

    task = claim_task(seat_token, login, "Reorder to continue")
    wait_on_limit(seat, task, login)
    key = new_key("reorder")
    complete("reorder_credentials", key: key, body: { "order" => [ login, spare, token ] })
    assert_equal %w[credential.order_changed credential.order_changed hold.closed credential.switched inbox.resolved],
      events(key).map(&:type)
    assert_equal spare, Task.find(task).credential_id
    start_run(spare)

    key = new_key("rename")
    complete("rename_credential", ids: id_path(token), key: key, body: { "name" => "Renamed sample account" })
    assert_equal [ "credential.renamed", {} ], events(key).sole.then { |event| [ event.type, event.payload ] }
    assert_equal "Renamed sample account", list_credentials.last.dig("credential", "name")

    key = new_key("in-use")
    call("remove_credential", token: @owner, key: key, ids: id_path(login))
    assert_response :conflict
    assert_response_matches_contract
    assert_equal "credential_in_use", response.parsed_body.dig("refusal", "code")
    assert_empty events(key)
    assert Credential.exists?(login)

    refresh = complete("refresh_usage").fetch("helper_request_ids")
    requests = pick_up_batch("read_usage", refresh, [ login, spare, token ])
    [ login, spare ].each { |id| finish(requests.fetch(id), %w[reading_taken]) }
    key = new_key("remove")
    complete("remove_credential", ids: id_path(token), key: key)
    assert_equal [ "credential.removed" ], events(key).map(&:type)
    assert_late_result(requests.fetch(token))
    assert_equal [ login, spare ], list_credentials.map { |row| row.dig("credential", "id") }
    refute CredentialReading.exists?(credential_id: token)

    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id)
  end

  private

  def id_path(id) = { "id" => id }

  def complete(operation, token: @owner, ids: {}, key: new_key(operation), body: nil)
    call(operation, token: token, key: key, ids: ids, body: body)
    assert_response :ok, operation
    assert_response_matches_contract
    assert_equal "completed", response.parsed_body.fetch("outcome"), operation
    response.parsed_body["result"]
  end

  def events(key) = Event.where(workspace_id: @scenario.workspace_id, command_id: key).order(:seq).to_a

  def list_credentials
    call("list_credentials", token: @owner)
    assert_response :ok
    assert_response_matches_contract
    response.parsed_body.fetch("credentials")
  end

  def pickup(kind, credential_id = nil)
    call("get_helper_next", token: @helper, query: { "wait" => 0 })
    assert_response :ok
    assert_response_matches_contract
    request = response.parsed_body.fetch("request")
    assert request, "the helper receives #{kind}"
    assert_equal kind, request.fetch("kind")
    assert_equal credential_id, request.fetch("credential_id") if credential_id
    request
  end

  def pick_up_batch(kind, request_ids, credential_ids)
    requests = Array.new(credential_ids.size) { pickup(kind) }.index_by { |request| request.fetch("credential_id") }
    assert_equal request_ids, credential_ids.map { |id| requests.fetch(id).fetch("id") }
    requests
  end

  def finish(request, checks, key: new_key("result"))
    complete("report_request_result", token: @helper, ids: id_path(request.fetch("id")), key: key,
      body: { "result" => { "outcome" => "finished", "tool_version" => nil, "plan" => nil, "account_email" => nil,
                           "checks" => checks.map { |check| { "check" => check, "passed" => true, "failure" => nil } } } })
  end

  def add_account(name, provider, kind: "login")
    id = SecureRandom.uuid
    mask = "••••••••" if kind == "api_token"
    result = complete("add_credential", body: { "credential_id" => id, "kind" => kind, "provider" => provider,
      "name" => name, "masked_label" => mask, "model" => nil, "effort" => nil, "strength_rank" => nil })
    request = pickup("run_add_checks", id)
    assert_equal result.fetch("helper_request_id"), request.fetch("id")
    finish(request, add_checks(kind))
    first_read = pickup("read_usage", id)
    complete("report_reading", token: @helper, ids: id_path(id), body: reading(id))
    finish(first_read, %w[reading_taken])
    id
  end

  def add_checks(kind) = kind == "login" ? %w[tool_installed signed_in test_prompt] : %w[token_works]

  def verify_all(ids)
    requested = complete("verify_all_credentials").fetch("helper_request_ids")
    pick_up_batch("verify", requested, ids).each_value do |request|
      finish(request, add_checks(request.fetch("params").fetch("credential_kind")))
    end
  end

  def reading(id, observed_at: @scenario.database_now, percent_used: nil)
    figures = if percent_used
      [ { "label" => "5-hour session", "kind" => "limit", "window" => "five_hour",
          "percent_used" => percent_used, "reset_at" => nil, "value" => nil } ]
    else
      []
    end
    { "credential_id" => id, "observed_at" => observed_at.utc.iso8601(6), "state" => "ok",
      "figures" => figures, "resets" => nil, "tool_version" => nil }
  end

  def connect_builder(login)
    seat = complete("connect_seat", body: { "name" => "Made-up builder", "role" => "builder", "provider" => nil,
      "model" => nil, "effort" => nil, "strength_rank" => nil, "credential_id" => login }).fetch("seat_id")
    [ seat, start_run(login) ]
  end

  def start_run(credential_id)
    request = pickup("start_seat", credential_id)
    seat_token = complete("issue_seat_token", token: @helper, ids: id_path(request.fetch("id"))).fetch("seat_token")
    complete("report_run_started", token: @helper, ids: id_path(request.fetch("seat_id")),
      body: { "credential_id" => credential_id, "observed_at" => @scenario.database_now.utc.iso8601(6),
              "tool_version" => "9.9.9-made-up" })
    finish(request, [])
    seat_token
  end

  def claim_task(seat_token, login, title)
    task = complete("add_task", body: { "title" => title, "details" => "Made-up goal.", "priority" => "normal",
      "work_reference" => "~/work/made-up", "state" => "backlog" }).fetch("task_id")
    complete("complete_contract", ids: id_path(task), body: { "title" => title, "details" => "Made-up goal.\n\nBuild a sample.",
      "criteria" => [ { "text" => "Build the sample.", "kind" => "build" }, { "text" => "Review it.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => "~/work/made-up" })
    claimed = complete("claim_next_task", token: seat_token)
    assert_equal login, claimed.fetch("credential_id")
    assert_equal task, claimed.dig("task", "id")
    task
  end

  def wait_on_limit(seat, task, login)
    key = new_key("limit")
    complete("report_limit", token: @helper, key: key, ids: id_path(login),
      body: { "credential_id" => login, "seat_id" => seat, "task_id" => task, "review_id" => nil, "job_id" => nil,
              "window" => "five_hour", "reset_at" => nil, "observed_at" => @scenario.database_now.utc.iso8601(6),
              "tool_version" => "9.9.9-made-up" })
    assert_equal %w[credential.limit_reached hold.opened inbox.opened], events(key).map(&:type)
  end

  def assert_late_result(request)
    row = HelperRequest.find(request.fetch("id"))
    assert_equal "failed", row.state
    assert_nil row.result
    before = row.attributes
    key = new_key("late-result")
    finish(request, %w[reading_taken], key: key)
    assert_empty events(key)
    assert_equal before, row.reload.attributes
  end
end
