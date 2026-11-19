require "test_helper"

# The owner's reads over HTTP (milestone 2 plan WP9, MA-20, MA-29, IN-23,
# IN-33, IN-35): the board, the task page, the roster, the credentials, the
# system health and one helper request, each through Reads::Snapshot and
# each answer held to openapi.json by OpenapiAssertions. A snapshot cannot be
# opened inside a test's own transaction, so this is a CommittingTestCase
# (the plan's rule for the owner-read tests) that makes its requests through
# the integration session.
class OwnerReadsTest < CommittingTestCase
  include ActionDispatch::IntegrationTest::Behavior
  include OpenapiAssertions

  setup do
    @owner_token = scenario.owner_token
  end

  def owner_get(path, token: @owner_token)
    get path, headers: ({ "Authorization" => "Bearer #{token}" } if token).to_h
  end

  def assert_read(path)
    owner_get(path)
    assert_response :ok, response.body
    assert_response_matches_contract
    response.parsed_body
  end

  def last_seq = Workspace.find(scenario.workspace_id).last_seq

  def open_round_limit_hold(task)
    ActiveRecord::Base.transaction do
      Leverage::Holds.open(scenario.context, task: task, reason: "rounds_exceeded", facts: { round: 3 })
    end
  end

  # --- authentication -----------------------------------------------------------------------------------------------

  READS = %w[
    /v1/owner/board /v1/owner/seats /v1/owner/credentials /v1/owner/health /v1/owner/events
    /v1/owner/tasks/00000000-0000-4000-8000-000000000001 /v1/owner/helper-requests/00000000-0000-4000-8000-000000000002
    /v1/owner/seats/00000000-0000-4000-8000-000000000003/landing-prompt
  ].freeze

  test "every owner read is 401 without an owner token" do
    seat = scenario.seat
    READS.each do |path|
      [ nil, scenario.token_for(seat), scenario.helper_token ].each do |token|
        owner_get(path, token: token)
        assert_response :unauthorized, "#{path} with #{token.inspect}"
        assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
        assert_matches_component("TransportError", response.parsed_body)
      end
    end
  end

  test "an owner read never writes: it adds no commands row and no event" do
    scenario.task(state: "ready")
    before = [ Command.count, Event.count, last_seq ]
    %w[/v1/owner/board /v1/owner/seats /v1/owner/credentials /v1/owner/health /v1/owner/events].each { |path| assert_read(path) }
    assert_equal before, [ Command.count, Event.count, last_seq ]
  end

  # --- get_board ----------------------------------------------------------------------------------------------------

  test "the board lists every task with its state, and the log position it reflects" do
    builder = scenario.seat(role: "builder", credential: scenario.credential)
    scenario.seat(role: "reviewer")
    states = %w[imaginarium backlog ready working in_review done cancelled]
    tasks = states.to_h { |state| [ state, scenario.task(state: state, builder: (builder if state == "working"), title: "A #{state} task") ] }

    body = assert_read("/v1/owner/board")

    assert_equal last_seq, body["as_of_seq"]
    assert_equal true, body["reviewer_seat_exists"]
    assert_equal states.size, body["tasks"].size
    by_state = body["tasks"].to_h { |card| [ card.dig("task", "state"), card ] }
    states.each do |state|
      card = by_state.fetch(state)
      task = tasks.fetch(state)
      assert_equal task.id, card.dig("task", "id")
      assert_equal "A #{state} task", card.dig("task", "title")
      assert_equal false, card["blocked"]
      assert_equal [], card["hold_reasons"]
      assert_nil card["waiting_for_credential_id"]
      assert_nil card["waiting_until"]
      assert_nil card["inbox_item"]
    end
    working = by_state.fetch("working").fetch("task")
    assert_equal builder.id, working["holder_seat_id"]
    assert_equal builder.id, working["builder_seat_id"]
    assert_equal tasks.fetch("working").lease_due_at.iso8601(3), Time.iso8601(working["lease_due_at"]).iso8601(3)
    assert_equal 1, by_state.fetch("ready").dig("task", "contract_version")
    assert_equal "normal", by_state.fetch("ready").dig("task", "priority")
    assert_in_delta 0.0, by_state.fetch("ready").dig("task", "spent")
  end

  test "an empty workspace has an empty board and says no reviewer exists" do
    body = assert_read("/v1/owner/board")
    assert_equal [], body["tasks"]
    assert_equal false, body["reviewer_seat_exists"]
    assert_equal 0, body["as_of_seq"]
  end

  test "the board says no reviewer exists until a reviewer seat is connected, and not for a removed one (SC-11)" do
    scenario.task(state: "in_review", reviewer: scenario.seat(role: "reviewer").tap { |seat| scenario.remove(seat) })
    assert_equal false, assert_read("/v1/owner/board")["reviewer_seat_exists"]

    scenario.seat(role: "reviewer")
    assert_equal true, assert_read("/v1/owner/board")["reviewer_seat_exists"]
  end

  test "a task held past the round limit is blocked and carries its open Needs you item (MA-29)" do
    scenario.seat(role: "reviewer")
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    quiet = scenario.task(state: "ready")
    hold = open_round_limit_hold(task)

    body = assert_read("/v1/owner/board")

    card = body["tasks"].find { |candidate| candidate.dig("task", "id") == task.id }
    assert_equal true, card["blocked"]
    assert_equal [ "rounds_exceeded" ], card["hold_reasons"]
    item = card["inbox_item"]
    assert_equal "past_round_limit", item["kind"]
    assert_equal "open", item["state"]
    assert_equal [ "task", task.id, hold.id ], item.values_at("about_kind", "about_id", "hold_id")
    assert_equal({ "round" => 3 }, item["facts"])
    assert_equal %w[allow_another_round edit_contract cancel], item["choices"]
    assert_equal Event.where(type: "inbox.opened", subject_id: item["id"]).pick(:seq), item["opened_seq"]
    assert_nil item["resolved_at"]
    assert_equal false, body["tasks"].find { |candidate| candidate.dig("task", "id") == quiet.id }["blocked"]
    assert_equal last_seq, body["as_of_seq"]
  end

  test "a closed hold no longer blocks the task and its item is gone" do
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    hold = open_round_limit_hold(task)
    ActiveRecord::Base.transaction { Leverage::Holds.close(scenario.context, hold: hold, task: task, choice: "allow_another_round") }

    card = assert_read("/v1/owner/board")["tasks"].sole
    assert_equal false, card["blocked"]
    assert_equal [], card["hold_reasons"]
    assert_nil card["inbox_item"]
  end

  test "a task waiting on a credential names it and when it resets" do
    credential = scenario.credential
    reset = Time.current.change(usec: 0) + 3600
    credential.update_columns(limited_until: reset)
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    ActiveRecord::Base.transaction do
      Leverage::Holds.open(scenario.context, task: task, reason: "credential_limit", credential_id: credential.id)
    end

    card = assert_read("/v1/owner/board")["tasks"].sole
    assert_equal true, card["blocked"]
    assert_equal [ "credential_limit" ], card["hold_reasons"]
    assert_equal credential.id, card["waiting_for_credential_id"]
    assert_equal reset.iso8601, Time.iso8601(card["waiting_until"]).iso8601
  end

  test "another workspace's tasks never appear" do
    other = Scenario.new
    other.task(state: "ready")
    scenario.task(state: "backlog")
    assert_equal [ "backlog" ], assert_read("/v1/owner/board")["tasks"].map { |card| card.dig("task", "state") }
  end

  # --- get_task -----------------------------------------------------------------------------------------------------

  test "the task page has the contract, criteria with evidence, reviews, events and the names its log needs" do
    credential = scenario.credential(name: "Made-up Claude account")
    builder = scenario.seat(role: "builder", credential: credential, name: "Made-up builder")
    reviewer = scenario.seat(role: "reviewer", name: "Made-up reviewer")
    task = scenario.task(state: "in_review", builder: builder, details: "Some details.")
    scenario.review(task, reviewer: reviewer)
    criterion = Criterion.where(task_id: task.id, kind: "build").sole
    Evidence.create!(workspace_id: scenario.workspace_id, criterion_id: criterion.id, kind: "note", value: "See the notes folder.",
      attached_by_seat_id: builder.id)
    removed = Criterion.create!(workspace_id: scenario.workspace_id, task_id: task.id, position: 9, kind: "build", text: "Gone.",
      removed_at: Time.current)

    body = assert_read("/v1/owner/tasks/#{task.id}")

    assert_equal task.id, body.dig("task", "id")
    assert_equal "in_review", body.dig("task", "state")
    assert_equal "Some details.", body.dig("task", "details")
    assert_equal last_seq, body["as_of_seq"]
    assert_equal true, body["reviewer_seat_exists"]
    assert_equal Criterion.where(task_id: task.id, removed_at: nil).order(:position).pluck(:id), body["criteria"].map { |row| row["id"] }
    refute_includes body["criteria"].map { |row| row["id"] }, removed.id
    with_proof = body["criteria"].find { |row| row["id"] == criterion.id }
    assert_equal [ { "id" => Evidence.where(criterion_id: criterion.id).sole.id, "criterion_id" => criterion.id, "kind" => "note", "value" => "See the notes folder." } ],
      with_proof["evidence"]
    assert_equal [], body["criteria"].find { |row| row["kind"] == "review" }["evidence"]
    assert_equal [ { "id" => Review.where(task_id: task.id).sole.id, "task_id" => task.id, "round" => task.round, "reviewer_seat_id" => reviewer.id,
                     "lease_due_at" => body["reviews"].sole["lease_due_at"], "verdict" => nil, "failed_criteria" => [], "notes" => nil } ],
      body["reviews"]
    assert_equal Event.where(task_id: task.id).order(:seq).pluck(:seq), body["events"].map { |event| event["seq"] }
    assert_equal Event.where(task_id: task.id).order(:seq).pluck(:type), body["events"].map { |event| event["type"] }
    assert_equal [], body["actions"]
    assert_equal [], body["questions"]
    assert_equal [], body["holds"]
    assert_equal [], body["inbox_items"]
    names = body["names"].to_h { |name| [ [ name["kind"], name["id"] ], name["name"] ] }
    assert_equal "Made-up builder", names[[ "seat", builder.id ]]
    assert_equal "Made-up reviewer", names[[ "seat", reviewer.id ]]
    assert_equal "Made-up Claude account", names[[ "credential", credential.id ]]
  end

  test "an event in the task's log has no hidden column and keeps its payload" do
    task = scenario.task(state: "ready")
    body = assert_read("/v1/owner/tasks/#{task.id}")
    created = body["events"].find { |event| event["type"] == "task.created" }
    assert_equal({ "state" => "backlog" }, created["payload"])
    assert_equal scenario.workspace_id, created["workspace_id"]
    refute created.key?("xact_id")
    refute created.key?("created_at")
  end

  test "the task page lists its holds and its open Needs you items, and a closed hold's item is not open" do
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    hold = open_round_limit_hold(task)

    body = assert_read("/v1/owner/tasks/#{task.id}")
    assert_equal [ hold.id ], body["holds"].map { |row| row["id"] }
    assert_equal "rounds_exceeded", body["holds"].sole["reason"]
    assert_nil body["holds"].sole["closed_at"]
    assert_equal [ "past_round_limit" ], body["inbox_items"].map { |item| item["kind"] }
    assert_equal %w[hold.opened inbox.opened], body["events"].last(2).map { |event| event["type"] }

    ActiveRecord::Base.transaction { Leverage::Holds.close(scenario.context, hold: hold, task: task, choice: "cancel") }
    body = assert_read("/v1/owner/tasks/#{task.id}")
    assert_equal [ hold.id ], body["holds"].map { |row| row["id"] }
    assert body["holds"].sole["closed_at"]
    assert_equal [], body["inbox_items"]
  end

  test "a task that is not in the owner's workspace, or does not exist, or is not a UUID, is 404" do
    other = Scenario.new
    foreign = other.task(state: "ready")
    [ foreign.id, SecureRandom.uuid, "not-an-id" ].each do |id|
      owner_get("/v1/owner/tasks/#{id}")
      assert_response :not_found, id
      assert_equal "not_found", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  # --- list_seats ---------------------------------------------------------------------------------------------------

  test "the roster lists each seat that is not removed, in the order they were connected" do
    credential = scenario.credential
    first = scenario.seat(role: "builder", credential: credential, name: "First", model: "")
    removed = scenario.seat(role: "builder", name: "Removed")
    scenario.remove(removed)
    second = scenario.seat(role: "reviewer", provider: "codex", name: "Second", model: "made-up-model", effort: "high")
    first.update_columns(run_state: "running", wanted_running: true, last_polled_at: Time.current.change(usec: 0))

    body = assert_read("/v1/owner/seats")

    assert_equal last_seq, body["as_of_seq"]
    assert_equal [ first.id, second.id ], body["seats"].map { |seat| seat["id"] }
    one, two = body["seats"]
    assert_equal({ "name" => "First", "provider" => "claude", "model" => nil, "effort" => nil, "role" => "builder",
                   "credential_id" => credential.id, "enabled" => true, "paused" => false, "run_state" => "running",
                   "wanted_running" => true, "removed_at" => nil },
      one.slice("name", "provider", "model", "effort", "role", "credential_id", "enabled", "paused", "run_state", "wanted_running",
        "removed_at"))
    assert one["last_polled_at"]
    assert_equal({ "provider" => "codex", "model" => "made-up-model", "effort" => "high", "credential_id" => nil,
                   "run_state" => nil, "last_polled_at" => nil, "wanted_running" => false },
      two.slice("provider", "model", "effort", "credential_id", "run_state", "last_polled_at", "wanted_running"))
  end

  test "the roster carries no token or digest" do
    scenario.seat(role: "builder")
    owner_get("/v1/owner/seats")
    assert_no_match(/token/, response.body)
    assert_no_match(/lvs_/, response.body)
    assert_no_match(/digest|hash/, response.body)
  end

  # --- list_credentials ---------------------------------------------------------------------------------------------

  test "the credentials list leaves out a row whose add is still running (IN-24)" do
    first = scenario.credential(name: "First account")
    scenario.credential(name: "Still adding", added: false)
    second = scenario.credential(name: "Second account", provider: "codex", plan: "Made-up plan",
      account_email: "someone@example.test")
    second.update_columns(state: "signed_out")

    body = assert_read("/v1/owner/credentials")

    assert_equal last_seq, body["as_of_seq"]
    assert_equal [ first.id, second.id ], body["credentials"].map { |row| row.dig("credential", "id") }
    assert_equal [ nil, nil ], body["credentials"].map { |row| row["reading"] }
    one = body["credentials"].first["credential"]
    assert_equal({ "kind" => "login", "provider" => "claude", "name" => "First account", "state" => "active", "position" => 1,
                   "limited_until" => nil, "masked_label" => nil, "model" => nil, "effort" => nil, "strength_rank" => nil },
      one.slice("kind", "provider", "name", "state", "position", "limited_until", "masked_label", "model", "effort", "strength_rank"))
    assert one["last_verified_at"]
    assert_equal "signed_out", body["credentials"].last.dig("credential", "state")
    assert_equal "Made-up plan", body["credentials"].last.dig("credential", "plan")
  end

  # --- get_system_health ----------------------------------------------------------------------------------------------

  test "the health line says the sweep is late when it never ran, and counts the queues (IN-33)" do
    scenario.seat(role: "reviewer")
    scenario.task(state: "ready")
    scenario.task(state: "ready")
    scenario.task(state: "backlog")
    waiting = scenario.task(state: "in_review")
    scenario.review(scenario.task(state: "in_review"))
    helper = scenario.helper
    HelperRequest.create!(workspace_id: scenario.workspace_id, kind: "install_tool", state: "queued", requested_at: Time.current,
      params: { "provider" => "claude" })
    HelperRequest.create!(workspace_id: scenario.workspace_id, kind: "verify", state: "picked_up", requested_at: Time.current)
    reported = Time.current.change(usec: 0) - 5
    helper.update_columns(last_reported_at: reported)

    body = assert_read("/v1/owner/health")

    assert_nil body["sweep_last_ran_at"]
    assert_equal true, body["sweep_late"]
    assert_equal reported.iso8601, Time.iso8601(body["helper_last_reported_at"]).iso8601
    assert_equal 1, body["queued_helper_requests"]
    assert_equal 2, body["ready_tasks"]
    assert_equal 1, body["waiting_reviews"], "only the review no reviewer holds is waiting (#{waiting.id})"
    assert_equal "not_set_up", body["orchestrator"]
  end

  test "the sweep is late when its last run is more than 120 seconds old, and not before" do
    ran_at = scenario.database_now - 100
    SweepRun.create!(workspace_id: scenario.workspace_id, ran_at: ran_at, tasks_touched: 0, workspace_timers_fired: 0)
    body = assert_read("/v1/owner/health")
    assert_equal false, body["sweep_late"]
    assert_in_delta ran_at.to_f, Time.iso8601(body["sweep_last_ran_at"]).to_f, 0.01

    SweepRun.create!(workspace_id: scenario.workspace_id, ran_at: scenario.database_now - 121, tasks_touched: 0,
      workspace_timers_fired: 0)
    assert_equal false, assert_read("/v1/owner/health")["sweep_late"], "the latest run counts, not the oldest"

    SweepRun.where(workspace_id: scenario.workspace_id).delete_all
    SweepRun.create!(workspace_id: scenario.workspace_id, ran_at: scenario.database_now - 121, tasks_touched: 0,
      workspace_timers_fired: 0)
    assert_equal true, assert_read("/v1/owner/health")["sweep_late"]
  end

  # --- get_helper_request -----------------------------------------------------------------------------------------

  def helper_request(**columns)
    scenario.credential(added: false).then do |credential|
      HelperRequest.create!({ workspace_id: scenario.workspace_id, kind: "run_add_checks", credential_id: credential.id,
                              state: "picked_up", requested_at: Time.current, picked_up_at: Time.current,
                              params: { "provider" => "claude", "credential_kind" => "login" },
                              progress: [ { "check" => "tool_installed", "state" => "passed", "failure" => nil, "install" => nil },
                                          { "check" => "signed_in", "state" => "waiting_for_sign_in", "failure" => nil, "install" => nil } ] }
        .merge(columns))
    end
  end

  test "a helper request is read with each check's progress and the log position" do
    request = helper_request

    body = assert_read("/v1/owner/helper-requests/#{request.id}")

    assert_equal last_seq, body["as_of_seq"]
    read = body["request"]
    assert_equal({ "id" => request.id, "kind" => "run_add_checks", "state" => "picked_up", "seat_id" => nil,
                   "credential_id" => request.credential_id, "finished_at" => nil, "result" => nil,
                   "params" => { "provider" => "claude", "credential_kind" => "login" } },
      read.slice("id", "kind", "state", "seat_id", "credential_id", "finished_at", "result", "params"))
    assert_equal %w[tool_installed signed_in], read["progress"].map { |check| check["check"] }
    assert_equal %w[passed waiting_for_sign_in], read["progress"].map { |check| check["state"] }
    assert_equal request.reload.updated_at, Time.iso8601(read["updated_at"]), "updated_at keeps its microseconds"
  end

  test "a helper request that is not in the workspace, does not exist or is not a UUID is 404" do
    other = Scenario.new
    foreign = HelperRequest.create!(workspace_id: other.workspace_id, kind: "stop_seat", requested_at: Time.current)
    [ foreign.id, SecureRandom.uuid, "not-an-id" ].each do |id|
      owner_get("/v1/owner/helper-requests/#{id}")
      assert_response :not_found, id
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  test "changed_after with a change since answers at once, whatever wait says" do
    request = helper_request
    seen = Time.iso8601(assert_read("/v1/owner/helper-requests/#{request.id}").dig("request", "updated_at"))
    request.update!(state: "finished", finished_at: Time.current, updated_at: seen + 1)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    owner_get("/v1/owner/helper-requests/#{request.id}?wait=10&changed_after=#{CGI.escape(seen.utc.iso8601(6))}")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_response :ok
    assert_response_matches_contract
    assert_equal "finished", response.parsed_body.dig("request", "state")
    assert_operator elapsed, :<, 3
  end

  test "changed_after with no change waits for wait seconds and then answers the unchanged request" do
    request = helper_request
    seen = Time.iso8601(assert_read("/v1/owner/helper-requests/#{request.id}").dig("request", "updated_at"))

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    owner_get("/v1/owner/helper-requests/#{request.id}?wait=1&changed_after=#{CGI.escape(seen.utc.iso8601(6))}")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_response :ok
    assert_response_matches_contract
    assert_equal "picked_up", response.parsed_body.dig("request", "state")
    assert_operator elapsed, :>=, 0.9
    assert_operator elapsed, :<, 4
  end

  test "wait without changed_after, or wait 0, answers at once" do
    request = helper_request
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    owner_get("/v1/owner/helper-requests/#{request.id}?wait=5")
    owner_get("/v1/owner/helper-requests/#{request.id}?wait=0&changed_after=#{CGI.escape((Time.current + 60).utc.iso8601(6))}")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
    assert_response :ok
  end

  test "a wait over 30, a negative or non-numeric wait and a changed_after that is not a time are 400 malformed" do
    request = helper_request
    [ "wait=31", "wait=-1", "wait=soon", "changed_after=yesterday", "wait=1.5" ].each do |query|
      owner_get("/v1/owner/helper-requests/#{request.id}?#{query}")
      assert_response :bad_request, query
      assert_equal "malformed", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  test "a helper request carries no token and no credential name" do
    credential = scenario.credential(added: false, name: "Name that must stay in its row")
    request = HelperRequest.create!(workspace_id: scenario.workspace_id, kind: "run_add_checks", credential_id: credential.id,
      requested_at: Time.current, params: { "provider" => "claude" })
    owner_get("/v1/owner/helper-requests/#{request.id}")
    assert_no_match(/Name that must stay/, response.body)
    assert_no_match(/token/, response.body)
  end
end
