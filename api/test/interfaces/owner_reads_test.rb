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
    # backup_runs belongs to the database, not to a workspace (HB-4), and a
    # committing test leaves its rows behind: start from none.
    BackupRun.delete_all
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
    credential.update_columns(limited_since: Time.current.change(usec: 0), limited_until: reset)
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

  test "a task held for a signed-out account names it and has no time (HE-12)" do
    credential = scenario.credential(limited_until: Time.current + 3600)
    scenario.sign_out_credential(credential)
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    scenario.hold(task, reason: "credential_signed_out", credential: credential)

    card = assert_read("/v1/owner/board")["tasks"].sole

    assert_equal [ "credential_signed_out" ], card["hold_reasons"]
    assert_equal credential.id, card["waiting_for_credential_id"]
    assert_nil card["waiting_until"], "a signed-out account has no reset time (rule 8)"
  end

  # A Ready task whose wait_ready step names credential_limit (HE-35): the
  # event that opens that step is task.released with the cause.
  def waiting_ready_task(cause: "credential_limit")
    task = scenario.task(state: "ready")
    scenario.append("task.released", task: task, payload: { reason: "unable_to_continue", wait_cause: cause })
    task
  end

  def ready_card(task) = assert_read("/v1/owner/board")["tasks"].find { |card| card.dig("task", "id") == task.id }

  test "a Ready task waiting on a provider limit names the account that resets first and the time (HM-40)" do
    first = scenario.credential(name: "First account")
    second = scenario.credential(name: "Second account")
    scenario.seat(role: "builder", credential: first)
    soon = Time.current.change(usec: 0) + 1800
    scenario.limit_credential(first, reset_at: soon + 3600)
    scenario.limit_credential(second, reset_at: soon)
    task = waiting_ready_task

    card = ready_card(task)

    assert_equal "ready", card.dig("task", "state")
    assert_equal false, card["blocked"]
    assert_equal second.id, card["waiting_for_credential_id"]
    assert_equal soon.iso8601, Time.iso8601(card["waiting_until"]).iso8601
    assert_nil card["inbox_item"]
  end

  test "a Ready task waiting on a limit with no reset time names the limited account and no time" do
    credential = scenario.credential
    scenario.seat(role: "builder", credential: credential)
    scenario.limit_credential(credential)
    task = waiting_ready_task

    card = ready_card(task)

    assert_equal credential.id, card["waiting_for_credential_id"]
    assert_nil card["waiting_until"]
  end

  test "a Ready task whose step names no limit says nothing about accounts, and neither does one an account can take" do
    credential = scenario.credential
    scenario.seat(role: "builder", credential: credential)
    plain = scenario.task(state: "ready")
    assert_nil ready_card(plain)["waiting_for_credential_id"]

    scenario.limit_credential(credential, reset_at: Time.current + 600)
    assert_nil ready_card(plain)["waiting_for_credential_id"], "the step names no limit, so the card does not claim one"

    scenario.limit_credential(credential, reset_at: Time.current - 5)
    named = waiting_ready_task
    assert_nil ready_card(named)["waiting_for_credential_id"], "its reset passed: an account is available"
  end

  test "a Ready task is not waiting on a limit while another seat's account is available" do
    limited = scenario.credential
    scenario.seat(role: "builder", credential: limited)
    scenario.seat(role: "builder", credential: scenario.credential)
    scenario.limit_credential(limited, reset_at: Time.current + 600)
    task = waiting_ready_task

    assert_nil ready_card(task)["waiting_for_credential_id"]
  end

  test "a Ready task no agent can start because every account is signed out names the account and opens no item (HE-16)" do
    credential = scenario.credential(name: "Signed-out account")
    scenario.seat(role: "builder", credential: credential)
    scenario.sign_out_credential(credential)
    task = scenario.task(state: "ready")

    card = ready_card(task)

    assert_equal credential.id, card["waiting_for_credential_id"]
    assert_nil card["waiting_until"]
    assert_nil card["inbox_item"]
    assert_equal false, card["blocked"]
    assert_equal 0, InboxItem.where(workspace_id: scenario.workspace_id).count
  end

  test "a task In review that no reviewer can take names the limited reviewer account and when it resets (HE-15)" do
    credential = scenario.credential(name: "Reviewer account")
    scenario.seat(role: "reviewer", credential: credential)
    scenario.seat(role: "builder")
    reset = Time.current.change(usec: 0) + 900
    scenario.limit_credential(credential, reset_at: reset)
    task = scenario.task(state: "in_review")

    card = ready_card(task)

    assert_equal "in_review", card.dig("task", "state")
    assert_equal credential.id, card["waiting_for_credential_id"]
    assert_equal reset.iso8601, Time.iso8601(card["waiting_until"]).iso8601
    assert_nil card["inbox_item"], "no item opens for it in this milestone"
    assert_equal false, card["blocked"]
  end

  test "a task In review that no reviewer can take because the account is signed out names it, with no time (HE-15)" do
    credential = scenario.credential
    scenario.seat(role: "reviewer", credential: credential)
    scenario.sign_out_credential(credential)
    task = scenario.task(state: "in_review")

    card = ready_card(task)

    assert_equal credential.id, card["waiting_for_credential_id"]
    assert_nil card["waiting_until"]
  end

  test "a task In review says nothing about accounts when a reviewer can take it, when one has begun, or when there is none" do
    taken = scenario.task(state: "in_review")
    assert_nil ready_card(taken)["waiting_for_credential_id"], "no reviewer seat exists"

    free = scenario.credential
    scenario.seat(role: "reviewer", credential: free)
    scenario.seat(role: "reviewer")
    assert_nil ready_card(taken)["waiting_for_credential_id"], "a reviewer with an available account and one that connects on its own"

    limited = scenario.credential
    scenario.limit_credential(limited, reset_at: Time.current + 600)
    scenario.limit_credential(free, reset_at: Time.current + 600)
    own = scenario.seat(role: "reviewer", credential: limited)
    assert_nil ready_card(taken)["waiting_for_credential_id"], "a reviewer that connects on its own can always begin"

    scenario.remove(Seat.where(workspace_id: scenario.workspace_id, role: "reviewer", credential_id: nil).sole)
    begun = scenario.task(state: "in_review")
    scenario.review(begun, reviewer: own)
    assert_nil ready_card(begun)["waiting_for_credential_id"], "its review has begun"
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

  # HE-15, HE-16: the task page names the account a task waits for exactly
  # as its board card does, from the same reading.
  WAITING = %w[waiting_for_credential_id waiting_until].freeze

  def page_and_card(task)
    page = assert_read("/v1/owner/tasks/#{task.id}")
    [ page.slice(*WAITING), ready_card(task).slice(*WAITING) ]
  end

  test "the task page names the signed-out account a Ready task waits for, as its card does (HE-16)" do
    credential = scenario.credential(name: "Signed-out account")
    scenario.seat(role: "builder", credential: credential)
    scenario.sign_out_credential(credential)
    task = scenario.task(state: "ready")

    page, card = page_and_card(task)

    assert_equal({ "waiting_for_credential_id" => credential.id, "waiting_until" => nil }, page)
    assert_equal card, page
  end

  test "the task page names the limited account a task In review waits for and when it resets, as its card does (HE-15)" do
    credential = scenario.credential(name: "Reviewer account")
    scenario.seat(role: "reviewer", credential: credential)
    reset = Time.current.change(usec: 0) + 900
    scenario.limit_credential(credential, reset_at: reset)
    task = scenario.task(state: "in_review")

    page, card = page_and_card(task)

    assert_equal credential.id, page["waiting_for_credential_id"]
    assert_equal reset.iso8601, Time.iso8601(page["waiting_until"]).iso8601
    assert_equal card, page
  end

  test "the task page names a credential hold's account, with its reset time only while it is active, as its card does" do
    limited = scenario.credential(name: "Limited account")
    reset = Time.current.change(usec: 0) + 3600
    scenario.limit_credential(limited, reset_at: reset)
    working = scenario.task(state: "working", builder: scenario.seat(role: "builder", credential: limited))
    scenario.hold(working, reason: "credential_limit", credential: limited)
    signed_out = scenario.credential(name: "Signed-out account", limited_until: Time.current + 3600)
    scenario.sign_out_credential(signed_out)
    stopped = scenario.task(state: "working", builder: scenario.seat(role: "builder", credential: signed_out))
    scenario.hold(stopped, reason: "credential_signed_out", credential: signed_out)

    page, card = page_and_card(working)
    assert_equal limited.id, page["waiting_for_credential_id"]
    assert_equal reset.iso8601, Time.iso8601(page["waiting_until"]).iso8601
    assert_equal card, page

    page, card = page_and_card(stopped)
    assert_equal({ "waiting_for_credential_id" => signed_out.id, "waiting_until" => nil }, page)
    assert_equal card, page
  end

  test "the task page names no account for a task that waits for none, nor for a credential hold that closed" do
    task = scenario.task(state: "ready")

    page, card = page_and_card(task)

    assert_equal({ "waiting_for_credential_id" => nil, "waiting_until" => nil }, page)
    assert_equal card, page

    credential = scenario.credential
    scenario.limit_credential(credential, reset_at: Time.current.change(usec: 0) + 3600)
    working = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    scenario.hold(working, reason: "credential_limit", credential: credential).update_columns(closed_at: Time.current)

    page, card = page_and_card(working)

    assert_equal({ "waiting_for_credential_id" => nil, "waiting_until" => nil }, page)
    assert_equal card, page
  end

  test "the task page carries the task's recovery times, oldest start first (HE-17)" do
    credential = scenario.credential(name: "Made-up Claude account")
    task = scenario.task(state: "ready")
    times = [ { kind: "limit", credential_id: credential.id, review_id: nil, started_at: "2026-01-01T00:10:00.000000Z",
                ended_at: "2026-01-01T00:10:00.000000Z", seconds: 0, ended_by: "handoff" },
              { kind: "signed_out", credential_id: credential.id, review_id: nil, started_at: "2026-01-01T01:00:00.000000Z",
                ended_at: nil, seconds: 300, ended_by: nil } ]
    seen = nil
    fake = lambda do |workspace_id, task_id: nil, now: nil|
      seen = [ workspace_id, task_id ]
      times
    end

    original = Leverage::Reads::RecoveryTimes.method(:call)
    begin
      Leverage::Reads::RecoveryTimes.define_singleton_method(:call, &fake)
      assert_read("/v1/owner/tasks/#{task.id}")
    ensure
      Leverage::Reads::RecoveryTimes.define_singleton_method(:call, original)
    end

    assert_equal [ scenario.workspace_id, task.id ], seen
    assert_equal times.map(&:deep_stringify_keys), response.parsed_body["recovery_times"]
  end

  test "the task page has no recovery times while the task has none" do
    task = scenario.task(state: "ready")

    assert_equal [], assert_read("/v1/owner/tasks/#{task.id}")["recovery_times"]
  end

  test "the task page names the credentials its handoff events carry (HE-17)" do
    from = scenario.credential(name: "Account the work left")
    to = scenario.credential(name: "Account the work went to")
    seat = scenario.seat(role: "builder", credential: from)
    task = scenario.task(state: "working", builder: seat)
    scenario.append("credential.switched", task: task, subject: to, payload: { seat_id: seat.id, from_credential_id: from.id,
      model: nil, review_id: nil, job_id: nil })

    names = assert_read("/v1/owner/tasks/#{task.id}")["names"].to_h { |name| [ [ name["kind"], name["id"] ], name["name"] ] }

    assert_equal "Account the work left", names[[ "credential", from.id ]]
    assert_equal "Account the work went to", names[[ "credential", to.id ]]
  end

  test "an event in the task's log has no hidden column and keeps its payload" do
    task = scenario.task(state: "ready")
    body = assert_read("/v1/owner/tasks/#{task.id}")
    created = body["events"].find { |event| event["type"] == "task.created" }
    assert_equal({ "state" => "backlog", "added_action_ids" => [] }, created["payload"])
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

  test "the roster says which credential each run is on and why its last run ended (HD-3, HD-10)" do
    own = scenario.credential
    other = scenario.credential
    running = scenario.seat(role: "builder", credential: own)
    stopped = scenario.seat(role: "builder", credential: own)
    waiting = scenario.seat(role: "builder")
    scenario.run(running, on: other)
    stopped.update_columns(run_credential_id: nil, run_state: "stopped", run_stop_reason: "limit")

    seats = assert_read("/v1/owner/seats")["seats"].to_h { |seat| [ seat["id"], seat ] }

    assert_equal [ other.id, nil ], seats.fetch(running.id).values_at("run_credential_id", "run_stop_reason")
    assert_equal [ nil, "limit" ], seats.fetch(stopped.id).values_at("run_credential_id", "run_stop_reason")
    assert_equal [ nil, nil ], seats.fetch(waiting.id).values_at("run_credential_id", "run_stop_reason")
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

  test "the credentials list carries limited_since with limited_until, and a reset that passed writes nothing (HE-3)" do
    since = Time.current.change(usec: 0) - 60
    reset = Time.current.change(usec: 0) + 3600
    scenario.credential(name: "Plain")
    limited = scenario.credential(name: "Limited")
    open_ended = scenario.credential(name: "No reset time")
    scenario.limit_credential(limited, since: since, reset_at: reset)
    scenario.limit_credential(open_ended, since: since)

    by_name = assert_read("/v1/owner/credentials")["credentials"].to_h { |row| [ row.dig("credential", "name"), row.fetch("credential") ] }

    assert_equal [ nil, nil ], by_name.fetch("Plain").values_at("limited_since", "limited_until")
    assert_equal [ since.iso8601, reset.iso8601 ],
      by_name.fetch("Limited").values_at("limited_since", "limited_until").map { |value| Time.iso8601(value).iso8601 }
    assert_equal [ since.iso8601, nil ], [ Time.iso8601(by_name.fetch("No reset time")["limited_since"]).iso8601, by_name.fetch("No reset time")["limited_until"] ]
  end

  test "the credentials list still leaves out a row whose add is running, limited or not (IN-24)" do
    running = scenario.credential(name: "Still adding", added: false)
    running.update_columns(limited_since: Time.current)
    shown = scenario.credential(name: "Added")

    assert_equal [ shown.id ], assert_read("/v1/owner/credentials")["credentials"].map { |row| row.dig("credential", "id") }
  end

  test "the credentials list pairs each added credential in handoff order with its newest reading or null" do
    token = scenario.token_credential(position: 4)
    running = scenario.credential(added: false, position: 2)
    login = scenario.credential(position: 1)
    unread = scenario.credential(position: 3)
    other = Scenario.new
    foreign = other.credential
    now = scenario.database_now
    observed_at = now - 30
    figures = [ { "label" => "Five hours", "kind" => "limit", "window" => "five_hour",
                  "percent_used" => 0, "reset_at" => nil, "value" => nil } ]
    resets = [ { "kind" => "five_hour", "count" => 0, "expires_at" => nil } ]

    scenario.reading(login, observed_at: observed_at, created_at: now - 10, tool_version: "0.0.0-made-up", figures: figures, resets: resets)
    scenario.reading(login, observed_at: now - 60, created_at: now, state: "unavailable")
    scenario.reading(token, observed_at: now, state: "unavailable")
    scenario.reading(running, observed_at: now)
    other.reading(foreign, observed_at: now)

    body = assert_read("/v1/owner/credentials")

    assert_equal last_seq, body["as_of_seq"]
    rows = body["credentials"]
    assert_equal [ login.id, unread.id, token.id ], rows.map { |row| row.dig("credential", "id") }
    assert_equal({ "credential_id" => login.id, "observed_at" => observed_at.utc.iso8601(6), "state" => "ok",
                   "tool_version" => "0.0.0-made-up", "figures" => figures, "resets" => resets }, rows.first.fetch("reading"))
    assert_nil rows.second.fetch("reading")
    assert_equal({ "credential_id" => token.id, "observed_at" => now.utc.iso8601(6), "state" => "unavailable",
                   "tool_version" => nil, "figures" => [], "resets" => nil }, rows.last.fetch("reading"))
    assert_no_match(/"[^" ]*(?:token|secret|password|digest|hash)[^" ]*"\s*:/i, response.body)
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

  def backup(ran_at, name: "made-up-#{SecureRandom.hex(3)}.dump")
    BackupRun.create!(ran_at: ran_at, file_name: name, bytes: 1234)
  end

  test "the health line carries the newest backup's time and is not late within 26 hours (HB-4)" do
    backup(scenario.database_now - 30 * 3600)
    newest = scenario.database_now - 26 * 3600 + 60
    backup(newest)

    body = assert_read("/v1/owner/health")

    assert_in_delta newest.to_f, Time.iso8601(body["backup_last_ran_at"]).to_f, 0.01
    assert_equal false, body["backup_late"]
  end

  test "the backup is late when the newest is older than 26 hours (HB-4)" do
    backup(scenario.database_now - 26 * 3600 - 60)

    body = assert_read("/v1/owner/health")

    assert body["backup_last_ran_at"]
    assert_equal true, body["backup_late"]
  end

  test "with no backup, the backup is late only once the workspace is more than an hour old (HB-4)" do
    body = assert_read("/v1/owner/health")
    assert_nil body["backup_last_ran_at"]
    assert_equal false, body["backup_late"]

    Workspace.where(id: scenario.workspace_id).update_all(created_at: scenario.database_now - 59 * 60)
    assert_equal false, assert_read("/v1/owner/health")["backup_late"]

    Workspace.where(id: scenario.workspace_id).update_all(created_at: scenario.database_now - 61 * 60)
    assert_equal true, assert_read("/v1/owner/health")["backup_late"]
  end

  test "a backup is the database's, not a workspace's: another workspace's health sees the same newest dump (HB-4)" do
    newest = scenario.database_now - 3600
    backup(newest)
    other = Scenario.new

    owner_get("/v1/owner/health", token: other.owner_token)

    assert_response :ok
    assert_in_delta newest.to_f, Time.iso8601(response.parsed_body["backup_last_ran_at"]).to_f, 0.01
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
