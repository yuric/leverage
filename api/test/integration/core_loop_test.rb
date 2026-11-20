require "test_helper"
require_relative "../support/http_trace_runner"

# The core loop over HTTP (PRD L868, L893, L894; milestone 2 plan §5.2, WP17):
# golden trace 09, from Add task to Done through one failed review, sent
# through the three interfaces with the real entries behind them, then the
# replay and the log audit on the log it leaves. HttpTraceRunner builds the
# setup over HTTP and is the helper between commands. GET /v1/next is asked
# where the trace's next call depends on it: the builder is offered the
# task, the reviewer the review, and after the failed review the builder
# its rework. Since milestone 3 (its plan HD-3, HD-4) each seat's run is
# recorded on the login its start named, and a claim records that login.
class CoreLoopTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  TRACE = "09-core-loop-no-rules".freeze

  # What GET /v1/next answers the caller just before the command at that
  # index (0-based), by the trace's commands.
  NEXT_BEFORE = { 2 => "task", 9 => "review", 12 => "rework" }.freeze

  test "trace 09 runs over HTTP through the three interfaces, and its log replays and passes the audit" do
    runner = HttpTraceRunner.new(self, TRACE, next_before: NEXT_BEFORE).run
    assert_empty runner.failures, runner.failures.join("\n")

    workspace_id = runner.workspace_id
    assert_empty Leverage::Replay.diff(workspace_id), "the replay of the log"
    assert_empty Leverage::LogAudit.call(workspace_id), "the log audit, setup included"

    task = Task.find_by!(workspace_id: workspace_id)
    owner_token = runner.tokens.fetch("$user:owner")
    call("get_task", token: owner_token, ids: { "id" => task.id })
    assert_response :ok
    assert_response_matches_contract
    assert_equal "done", response.parsed_body.dig("task", "state")
    assert_equal 1, Review.where(task_id: task.id, verdict: "failed").count, "exactly one review failed"

    call("list_events", token: owner_token, query: { "after_seq" => 0, "limit" => 500, "wait" => 0 })
    assert_response :ok
    assert_response_matches_contract
    task_events = Event.where(workspace_id: workspace_id, task_id: task.id).order(:seq).pluck(:type)
    expected = Leverage::Contract.trace(TRACE).fetch("commands").flat_map do |command|
      command.dig("expect", "events").map { |event| event.fetch("type") }
    end
    assert_equal expected, task_events

    call("list_seats", token: owner_token)
    assert_response :ok
    assert_response_matches_contract
    response.parsed_body.fetch("seats").each do |seat|
      assert_equal seat.fetch("credential_id"), seat.fetch("run_credential_id"), "HD-3: #{seat.fetch("name")} runs on its own login"
    end
    claimed = Event.find_by!(workspace_id: workspace_id, type: "task.claimed")
    assert_equal Seat.find(claimed.payload.fetch("seat_id")).credential_id, claimed.payload.fetch("credential_id"), "HD-4: the claim's login"
  end
end
