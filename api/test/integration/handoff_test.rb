require "test_helper"
require_relative "../support/http_trace_runner"

# The three interrupted forms over HTTP (PRD L871, L901 to L905; milestone
# 3 plan HT-4, §5.2, WP10): the server's own walk of what the end-to-end
# run plays with stand-in tools. Each form is the rule-free golden trace
# that tells it, sent through the three interfaces with the real entries
# behind them, the helper handing each run over between commands
# (HttpTraceRunner), and compared event for event and step for step:
#
# - A, a limit after work is saved: trace 11. The first limit hands over
#   at once to the login below; the second finds none, waits under a
#   credential_limit hold for the earliest reset, and the credential timer
#   hands the work back to the seat's own login when it passes.
# - B, a login found signed out: first with a login below it available,
#   which takes over at once (trace 12's setup with that login signed in,
#   up to the report, then the report by hand); then trace 12 itself. No
#   login is left, so the task is held, Needs you opens "Account signed out", Sign in again queues the
#   helper's request and its passed result hands the work over.
# - C, one account at its limit while the next is signed out: trace 13.
#   The hold names the signed-out login, and its item; Sign in again on it
#   ends the wait.
#
# Then, on each log: the replay and the log audit, the saved work intact
# (one criterion.passed and one evidence.attached for the criterion passed
# before the interruption, nothing reopened, one claim, the same builder),
# and the recovery times of HE-17, read through get_task and compared in
# the trace's own seconds.
class HandoffTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  # The index (0-based) of the report that opens the item, by trace.
  ITEM_AFTER = { "12-signed-out-hold-verify-no-rules" => 7, "13-limit-next-signed-out-no-rules" => 7 }.freeze

  def run_form(trace)
    inbox_checks = []
    check = lambda do |index, runner|
      next unless ITEM_AFTER[trace] == index

      inbox_checks << open_item_after_report(runner)
    end
    runner = HttpTraceRunner.new(self, trace, after_command: check).run
    assert_empty runner.failures, runner.failures.join("\n")
    assert_equal [ true ], inbox_checks if ITEM_AFTER.key?(trace)
    runner
  end

  # After the report, the owner's list_inbox with after_seq and wait holds
  # the "Account signed out" item that names the login to sign in again.
  def open_item_after_report(runner)
    before = Event.where(workspace_id: runner.workspace_id, type: "inbox.opened").order(:seq).last.seq - 1
    call("list_inbox", token: runner.owner_token, query: { "after_seq" => before, "wait" => 1 })
    assert_response :ok
    assert_response_matches_contract
    item = response.parsed_body.fetch("items").sole
    assert_equal [ "account_signed_out", "open" ], item.values_at("kind", "state")
    assert_equal Credential.find(item.fetch("credential_id")).state, "signed_out", "the item names the signed-out login"
    assert_includes item.fetch("choices"), "sign_in_again"
    true
  end

  # Replay, audit, the saved work and the recovery times on the form's log.
  def assert_log(runner, recovery)
    workspace_id = runner.workspace_id
    assert_empty Leverage::Replay.diff(workspace_id), "the replay of the log"
    assert_empty Leverage::LogAudit.call(workspace_id), "the log audit, setup included"

    task = Task.find_by!(workspace_id: workspace_id)
    events = Event.where(workspace_id: workspace_id, task_id: task.id).order(:seq).to_a
    interrupted = events.find { |event| %w[credential.limit_reached credential.signed_out].include?(event.type) }
    first = Criterion.where(task_id: task.id, kind: "build").order(:position).first
    passed = events.select { |event| event.type == "criterion.passed" && event.subject_id == first.id }
    evidence = events.select { |event| event.type == "evidence.attached" && event.payload["criterion_id"] == first.id }
    assert_equal 1, passed.size, "criterion 1 passed once"
    assert_operator passed.sole.seq, :<, interrupted.seq, "before the interruption"
    assert_equal 1, evidence.size, "criterion 1 has its one evidence"
    assert_operator evidence.sole.seq, :<, interrupted.seq
    assert_empty events.select { |event| event.type == "criterion.reopened" }
    claims = events.select { |event| event.type == "task.claimed" }
    assert_equal 1, claims.size, "one claim"
    assert_equal claims.sole.payload.fetch("seat_id"), task.reload.builder_seat_id, "the builder never changed"

    call("get_task", token: runner.owner_token, ids: { "id" => task.id })
    assert_response :ok
    assert_response_matches_contract
    page = response.parsed_body
    assert_equal "done", page.dig("task", "state")
    passed_criterion = page.fetch("criteria").find { |criterion| criterion.fetch("id") == first.id }
    assert_equal "passed", passed_criterion.fetch("state")
    read = page.fetch("recovery_times")
    assert_equal Leverage::Reads::RecoveryTimes.call(workspace_id, task_id: task.id), read
    assert_equal recovery, in_trace(runner, read)
    read.each { |item| assert_operator item.fetch("seconds"), :<=, 900, "the working bar of 900 seconds" }
  end

  # The intervals in the trace's own seconds (recovery_time_test.rb): the
  # @t each end was bound to; the engine's seconds are its own clock's.
  def in_trace(runner, list)
    list.map do |item|
      ended = item.fetch("ended_at")
      length = ended && (runner.trace_seconds(ended) - runner.trace_seconds(item.fetch("started_at")))
      [ item.fetch("kind"), length, item.fetch("ended_by") ]
    end
  end

  test "A: a limit after work is saved hands over at once, then waits for the reset and goes back to the seat's own login" do
    runner = run_form("11-limit-handoff-no-rules")
    assert_log(runner, [ [ "limit", 0, "handoff" ], [ "limit", 1600, "seat_event" ] ])

    switches = Event.where(workspace_id: runner.workspace_id, type: "credential.switched").order(:seq).to_a
    builder = Seat.find_by!(workspace_id: runner.workspace_id, role: "builder")
    assert_equal builder.credential_id, switches.last.subject_id, "back on its own login"
    assert_equal builder.credential_id, builder.reload.run_credential_id, "the helper started its run there"
    task = Task.find_by!(workspace_id: runner.workspace_id)
    continued = HelperRequest.where(seat_id: builder.id, kind: "start_seat").order(:requested_at).select do |request|
      request.params["task_id"] == task.id
    end
    assert_equal switches.map(&:subject_id), continued.map(&:credential_id),
      "each hand-over started the run on the login switched to, naming the task to continue (HD-1)"
  end

  test "B: a login found signed out hands over at once to the login below it, and the work goes on there" do
    name = "12-signed-out-hold-verify-no-rules"
    trace = Leverage::Contract.trace(name).deep_dup
    trace.dig("setup", "credentials").each { |row| row["state"] = "active" }
    runner = HttpTraceRunner.new(self, name, trace: trace).run(7)
    assert_empty runner.failures, runner.failures.join("\n")
    workspace_id = runner.workspace_id
    task = Task.find_by!(workspace_id: workspace_id)
    builder = Seat.find(task.holder_seat_id)
    below = Credential.where(workspace_id: workspace_id, provider: "claude").where.not(id: builder.credential_id).sole

    before = Workspace.find(workspace_id).last_seq
    call("report_signed_out", token: runner.helper_token, key: new_key("signed-out"), ids: { "id" => builder.credential_id },
      body: { "credential_id" => builder.credential_id, "seat_id" => builder.id, "task_id" => task.id, "review_id" => nil,
              "job_id" => nil, "observed_at" => Time.current.utc.iso8601(6), "tool_version" => "0.0.0-made-up" })
    assert_response :ok
    assert_response_matches_contract
    assert_equal [ "completed", nil ], response.parsed_body.values_at("outcome", "result")
    written = Event.where(workspace_id: workspace_id).where("seq > ?", before).order(:seq).to_a
    assert_equal %w[credential.signed_out credential.switched], written.map(&:type)
    assert_equal below.id, written.last.subject_id
    assert_empty Hold.where(task_id: task.id)

    runner.helper_turn
    assert_equal below.id, builder.reload.run_credential_id, "the helper started the run on the login below"
    started = Event.where(workspace_id: workspace_id, type: "criterion.started").order(:seq).last
    call("pass_criterion", token: runner.tokens.fetch("$seat:builder"), key: new_key("pass"),
      ids: { "id" => task.id, "cid" => started.subject_id },
      body: { "evidence" => { "kind" => "link", "value" => "https://example.test/made-up/passed" } })
    assert_response :ok
    assert_equal "completed", response.parsed_body.fetch("outcome")

    assert_empty Leverage::Replay.diff(workspace_id), "the replay of the log"
    assert_empty Leverage::LogAudit.call(workspace_id), "the log audit, setup included"
    call("get_task", token: runner.owner_token, ids: { "id" => task.id })
    assert_response :ok
    assert_response_matches_contract
    times = response.parsed_body.fetch("recovery_times")
    assert_equal [ [ "signed_out", builder.credential_id, 0, "handoff" ] ],
      times.map { |item| item.values_at("kind", "credential_id", "seconds", "ended_by") }
    assert_equal written.last.effective_at.utc.iso8601(6), times.sole.fetch("ended_at")
  end

  test "B: a login found signed out with no other login holds the task until Sign in again passes" do
    runner = run_form("12-signed-out-hold-verify-no-rules")
    assert_log(runner, [ [ "signed_out", 300, "seat_event" ] ])
    assert_equal [ "open_sign_in" ], runner.picked_up.map { |request| request.fetch("kind") }
  end

  test "C: a limit while the next login is signed out holds the task for that login, and Sign in again on it ends the wait" do
    runner = run_form("13-limit-next-signed-out-no-rules")
    assert_log(runner, [ [ "limit", 220, "seat_event" ] ])
    hold = Hold.find_by!(workspace_id: runner.workspace_id, reason: "credential_signed_out")
    signed_in = runner.picked_up.sole
    assert_equal [ "open_sign_in", hold.credential_id ], signed_in.values_at("kind", "credential_id")
  end
end
