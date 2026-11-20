require "test_helper"

# list_inbox (milestone 3 plan WP7, HE-37, HE-40, HM-29): the open Needs you
# items of the workspace, each with the seq of its inbox.opened event;
# after_seq keeps only items opened after that seq; wait long-polls until
# one exists. It reads in a CommittingTestCase because the long poll's
# writer is a second connection, and it makes its requests through the
# integration session.
class InboxTest < CommittingTestCase
  include ActionDispatch::IntegrationTest::Behavior
  include OpenapiAssertions

  setup do
    @token = scenario.owner_token
    @builder = scenario.seat(role: "builder")
  end

  def inbox(query = nil, token: @token)
    get "/v1/owner/inbox#{"?#{query}" if query}", headers: ({ "Authorization" => "Bearer #{token}" } if token).to_h
  end

  def read(query = nil)
    inbox(query)
    assert_response :ok, response.body
    assert_response_matches_contract
    response.parsed_body
  end

  # A working task held at the round limit: its "past_round_limit" item opens.
  def held_task(title: "A made-up task")
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"), title: title)
    [ task, scenario.hold(task, reason: "rounds_exceeded", facts: { round: 3 }) ]
  end

  def opened_seq(item) = Event.where(type: "inbox.opened", subject_id: item.id).pick(:seq)

  def open_item(hold) = InboxItem.find_by!(hold_id: hold.id)

  test "an empty inbox is an empty list at position 0" do
    assert_equal({ "items" => [], "next_after_seq" => 0 }, read)
  end

  test "it lists every open item whatever its kind, each with the seq of its inbox.opened, oldest first" do
    task, hold = held_task
    other, other_hold = held_task(title: "Another task")
    credential = scenario.credential
    signed_out = scenario.hold(scenario.task(state: "ready"), reason: "credential_signed_out", credential: credential)

    body = read

    items = body["items"]
    assert_equal [ open_item(hold).id, open_item(other_hold).id, open_item(signed_out).id ], items.map { |item| item["id"] }
    assert_equal %w[past_round_limit past_round_limit account_signed_out], items.map { |item| item["kind"] }
    assert_equal items.map { |item| item["id"] }.map { |id| Event.where(type: "inbox.opened", subject_id: id).pick(:seq) },
      items.map { |item| item["opened_seq"] }
    assert_equal items.map { |item| item["opened_seq"] }.sort, items.map { |item| item["opened_seq"] }
    assert_equal [ "task", task.id, hold.id ], items.first.values_at("about_kind", "about_id", "hold_id")
    assert_equal [ credential.id ], [ items.last["credential_id"] ]
    assert_equal items.last["opened_seq"], body["next_after_seq"]
    assert_equal [ "open" ], items.map { |item| item["state"] }.uniq
    assert_equal other.id, items.second["about_id"]
  end

  test "a resolved item is not listed" do
    task, hold = held_task
    held_task(title: "Another task")
    ActiveRecord::Base.transaction { Leverage::Holds.close(scenario.context, hold: hold, task: task, choice: "cancel") }

    body = read

    assert_equal 1, body["items"].size
    refute_includes body["items"].map { |item| item["hold_id"] }, hold.id
  end

  test "after_seq keeps only the items opened after it, and next_after_seq is the greatest seq returned" do
    _, first = held_task
    _, second = held_task(title: "Second")
    _, third = held_task(title: "Third")
    seqs = [ first, second, third ].map { |hold| opened_seq(open_item(hold)) }

    assert_equal [ open_item(second).id, open_item(third).id ], read("after_seq=#{seqs.first}")["items"].map { |item| item["id"] }
    assert_equal [ open_item(third).id ], read("after_seq=#{seqs.second}")["items"].map { |item| item["id"] }
    assert_equal seqs.last, read("after_seq=#{seqs.second}")["next_after_seq"]
    assert_equal 3, read("after_seq=0")["items"].size
  end

  test "with nothing after it, next_after_seq is the after_seq it was given" do
    _, hold = held_task
    seq = opened_seq(open_item(hold))

    body = read("after_seq=#{seq}")

    assert_equal [], body["items"]
    assert_equal seq, body["next_after_seq"]
    assert_equal 9_999, read("after_seq=9999")["next_after_seq"]
  end

  test "an item that opened and was resolved after after_seq is not listed, and does not move the position" do
    task, hold = held_task
    ActiveRecord::Base.transaction { Leverage::Holds.close(scenario.context, hold: hold, task: task, choice: "cancel") }

    body = read("after_seq=0")

    assert_equal [], body["items"]
    assert_equal 0, body["next_after_seq"]
  end

  test "another workspace's items are never listed" do
    other = Scenario.new
    other_task = other.task(state: "working", builder: other.seat(role: "builder"))
    other.hold(other_task, reason: "rounds_exceeded", facts: { round: 3 })
    _, mine = held_task

    assert_equal [ open_item(mine).id ], read["items"].map { |item| item["id"] }
  end

  test "wait returns at once when an item exists" do
    held_task
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    body = read("after_seq=0&wait=10")

    assert_equal 1, body["items"].size
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  end

  test "wait returns when an item opens, long before wait runs out" do
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    writer = Thread.new do
      sleep 0.6
      scenario.hold(task, reason: "rounds_exceeded", facts: { round: 3 })
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    body = read("after_seq=#{Workspace.find(scenario.workspace_id).last_seq}&wait=20")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    writer.join

    assert_equal [ "past_round_limit" ], body["items"].map { |item| item["kind"] }
    assert_operator elapsed, :>=, 0.5
    assert_operator elapsed, :<, 8
  end

  test "wait with nothing opening answers an empty list when it runs out" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    body = read("wait=1")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal({ "items" => [], "next_after_seq" => 0 }, body)
    assert_operator elapsed, :>=, 0.9
    assert_operator elapsed, :<, 5
  end

  test "an after_seq or wait outside the contract's range is 400 malformed" do
    [ "after_seq=-1", "after_seq=soon", "after_seq=1.5", "wait=31", "wait=-1", "wait=soon", "wait=1.5" ].each do |query|
      inbox(query)

      assert_response :bad_request, query
      assert_equal "malformed", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  test "it is 401 without an owner token" do
    [ nil, scenario.token_for(@builder), scenario.helper_token ].each do |token|
      inbox(token: token)

      assert_response :unauthorized
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  # The workspace's "Orchestrator offline" item as the sweep's timer opens
  # it (WP7), with the count it had then (milestone 4 plan RD-16).
  def offline_item(waiting_checks:)
    ActiveRecord::Base.transaction do
      item = InboxItem.create!(workspace_id: scenario.workspace_id, kind: "orchestrator_offline", about_kind: "workspace",
        about_id: scenario.workspace_id, choices: [], opened_at: scenario.database_now,
        facts: { "role" => "orchestrator", "waiting_checks" => waiting_checks, "credential_id" => nil })
      scenario.append("inbox.opened", subject: item, payload: { kind: item.kind })
      item
    end
  end

  test "an open Orchestrator offline item says how many checks wait now, not when it opened (RD-18), as the health line does" do
    rule = scenario.rule
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    scenario.rule_check(task, rule: rule)
    item = offline_item(waiting_checks: 1)
    scenario.rule_check(task, rule: rule)
    scenario.rule_check(task, rule: rule)
    _, hold = held_task

    items = read["items"]

    offline = items.find { |entry| entry["id"] == item.id }
    assert_equal({ "role" => "orchestrator", "waiting_checks" => 3, "credential_id" => nil }, offline["facts"])
    assert_equal({ "round" => 3 }, items.find { |entry| entry["hold_id"] == hold.id }["facts"], "other items keep their facts")
    assert_equal 1, item.reload.facts["waiting_checks"], "the read writes nothing"
    health = Leverage::Reads::SystemHealth.call(scenario.workspace_id)
    assert_equal offline.dig("facts", "waiting_checks"), health[:waiting_checks]
  end

  test "it never writes: no command row and no event" do
    held_task
    before = [ Command.count, Event.count, Workspace.find(scenario.workspace_id).last_seq ]

    read
    read("after_seq=0&wait=1")

    assert_equal before, [ Command.count, Event.count, Workspace.find(scenario.workspace_id).last_seq ]
  end
end
