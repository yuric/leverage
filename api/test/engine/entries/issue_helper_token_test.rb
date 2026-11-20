require "test_helper"
require_relative "accounts_support"

# issue_helper_token (PRD L991; milestone 2 plan IN-11, IN-17, IN-30): the
# owner's app issues the helper a token each time it starts the helper. In
# the same transaction it ends the previous token, fails the previous
# helper's unfinished requests (deleting the row of an add still running),
# treats every seat still marked running as stopped, and queues start_seat
# for every seat that is wanted running.
class IssueHelperTokenTest < ActiveSupport::TestCase
  include AccountsSupport

  setup do
    @scenario = Scenario.new
    @scenario.owner
  end

  def issue(name: "Made-up Mac", **options) = owner_command("issue_helper_token", { "name" => name }, **options)

  test "the first issue makes the helper and shows its token once, stored only as a digest" do
    written = events_written { @outcome = assert_completed(issue(key: "first-helper-key")) }

    token = @outcome.once.fetch("helper_token")
    assert_match Leverage::Tokens::FORM, token
    assert token.start_with?("lvh_")
    helper = Helper.find(@outcome.result.fetch("helper_id"))
    assert_equal [ "Made-up Mac", Leverage::Tokens.digest(token) ], [ helper.name, helper.token_hash ]
    assert_equal helper.id, Leverage::Tokens.find(token, kind: :helper).id
    assert_equal [ "helper_id" ], @outcome.result.keys
    assert_empty written, "issuing the helper's token writes no event"
    stored = Command.find_by!(key: "first-helper-key")
    assert_equal @outcome.result, stored.result
    assert_not_includes stored.result.to_json, token
  end

  test "the next issue ends the previous token and keeps the one helper row" do
    first = assert_completed(issue)
    second = assert_completed(issue(name: "Made-up Mac again"))

    assert_nil Leverage::Tokens.find(first.once.fetch("helper_token"), kind: :helper), "the previous token ends"
    assert_equal second.result.fetch("helper_id"),
      Leverage::Tokens.find(second.once.fetch("helper_token"), kind: :helper).id
    assert_equal first.result.fetch("helper_id"), second.result.fetch("helper_id")
    assert_equal 1, Helper.where(workspace_id: @scenario.workspace_id).count
    assert_equal "Made-up Mac again", Helper.find(second.result.fetch("helper_id")).name
  end

  test "a repeat of the key answers the stored result, with no token and no new one issued" do
    first = assert_completed(issue(key: "repeat-helper-key"))
    digest = Helper.find(first.result.fetch("helper_id")).token_hash

    repeat = assert_completed(issue(key: "repeat-helper-key"))

    assert_nil repeat.once
    assert_equal first.result, repeat.result
    assert_equal digest, Helper.find(first.result.fetch("helper_id")).reload.token_hash
  end

  test "it fails every unfinished request and deletes the row of an add still running" do
    added = @scenario.credential(provider: "codex")
    adding = @scenario.credential(provider: "claude", added: false)
    queued_add = queue_request("run_add_checks", credential: adding, params: { "provider" => "claude", "credential_kind" => "login" })
    picked_verify = queue_request("verify", credential: added, state: "picked_up")
    seat = @scenario.seat(credential: added)
    queued_start = queue_request("start_seat", seat: seat)
    done = queue_request("install_tool", state: "finished", params: { "provider" => "codex" })

    outcome = assert_completed(issue)

    [ queued_add, picked_verify, queued_start ].each do |request|
      request.reload
      assert_equal "failed", request.state, "#{request.kind} is failed"
      assert_not_nil request.finished_at
      assert_equal "failed", request.result.fetch("outcome")
    end
    assert_equal "finished", done.reload.state
    assert_not Credential.exists?(adding.id), "the row of an add still running is deleted (IN-24)"
    assert Credential.exists?(added.id), "an added credential is never deleted"
    assert_not_nil outcome.result.fetch("helper_id")
  end

  test "every seat still marked running is treated as stopped, and a review it holds is released" do
    reviewer = running_seat(role: "reviewer")
    builder = running_seat(role: "builder")
    review_task = @scenario.task(state: "in_review")
    review = @scenario.review(review_task, reviewer: reviewer)
    work_task = @scenario.task(state: "working", builder: builder)

    written = events_written { @outcome = assert_completed(issue(key: "restart-key")) }

    [ reviewer, builder ].each do |seat|
      seat.reload
      assert_equal "stopped", seat.run_state
      assert_nil seat.token_hash, "the run's token ends with it (IN-17)"
      assert_not signs_in?(seat)
    end
    review.reload
    assert_nil review.reviewer_seat_id
    assert_nil review.lease_due_at
    released = written.select { |event| event.type == "review.released" }
    assert_equal 1, released.size
    assert_equal [ "review", review.id, review_task.id, "app", nil, "restart-key" ],
      [ released.first.subject_kind, released.first.subject_id, released.first.task_id, released.first.actor_kind,
        released.first.actor_id, released.first.command_id ]
    work_task.reload
    assert_equal [ "working", builder.id ], [ work_task.state, work_task.holder_seat_id ],
      "a builder's task waits for its lease to end (L121)"
    assert_equal [ "review.released" ], written.map(&:type)
  end

  test "it queues start_seat for every seat wanted running, with the seat's inputs and no name" do
    wanted = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"), model: "",
      effort: "high", run_state: "stopped", wanted_running: true)
    @scenario.seat(role: "builder", credential: @scenario.credential, run_state: "stopped", wanted_running: false)
    gone = @scenario.seat(role: "builder", credential: @scenario.credential(provider: "grok"), wanted_running: true)
    @scenario.remove(gone)

    assert_completed(issue)

    starts = HelperRequest.where(workspace_id: @scenario.workspace_id, kind: "start_seat", state: "queued").to_a
    assert_equal [ wanted.id ], starts.map(&:seat_id)
    start = starts.first
    assert_equal wanted.credential_id, start.credential_id
    assert_equal({ "role" => "reviewer", "provider" => "codex", "model" => nil, "effort" => "high" }, start.params)
    assert_not_includes start.attributes.to_json, wanted.name
  end

  test "a seat that was running and is wanted running is stopped and queued to start again" do
    seat = running_seat(role: "builder")

    assert_completed(issue)

    seat.reload
    assert_equal [ "stopped", true ], [ seat.run_state, seat.wanted_running ]
    assert_equal 1, HelperRequest.where(seat_id: seat.id, kind: "start_seat", state: "queued").count
  end
end
