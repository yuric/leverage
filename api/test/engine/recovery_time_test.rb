require "test_helper"
require_relative "../support/trace_runner"

# Recovery time (PRD test 11, L65, L319, L703; milestone 3 plan HE-17,
# HE-18): the interval between the event that records an interruption
# (credential.limit_reached, or credential.signed_out found during a run)
# and the credential.switched its own command wrote, or else the first
# later event of that work written by a seat. Reads and heartbeats write
# no event and do not end it; a credential.switched the app writes later
# ends nothing; a sign-out Verify finds starts nothing. Computed from the
# log alone by Leverage::Reads::RecoveryTimes, and printed, against a bar,
# by bin/rails leverage:recovery_times.
class RecoveryTimeTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  def run_trace(name, limit = nil)
    runner = TraceRunner.new(name)
    limit ? runner.run(limit) : runner.run
    assert_empty runner.failures, runner.failures.join("\n")
    runner
  end

  def times(runner, **options) = Leverage::Reads::RecoveryTimes.call(runner.workspace_id, **options)

  def summary(list) = list.map { |item| [ item.fetch("kind"), item.fetch("seconds"), item.fetch("ended_by") ] }

  def apply(runner, command, caller, params)
    T.apply(T::Request.new(command: command, workspace_id: runner.workspace_id, caller_kind: "seat", caller_id: caller.id,
      key: "recovery-#{SecureRandom.hex(6)}", request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end

  # --- the traces' recovery times (HT-1) ------------------------------------------------

  test "trace 11: the first limit hands off at once (0 s); the second waits for the reset and ends at the seat's criterion.passed (1600 s)" do
    list = times(run_trace("11-limit-handoff-no-rules"))
    assert_equal [ [ "limit", 0, "handoff" ], [ "limit", 1600, "seat_event" ] ], summary(list)

    first, second = list
    assert_equal first.fetch("started_at"), first.fetch("ended_at")
    builder = Seat.find_by!(workspace_id: runner_id(list), role: "builder")
    assert_equal builder.credential_id, first.fetch("credential_id"), "the seat's own login stopped first"
    refute_equal builder.credential_id, second.fetch("credential_id"), "then the login it was handed to"
    assert_nil second.fetch("review_id")
    passed = Event.where(workspace_id: builder.workspace_id, type: "criterion.passed").order(:seq).last
    assert_equal passed.effective_at.utc.iso8601(6), second.fetch("ended_at")
  end

  def runner_id(list) = Credential.find(list.first.fetch("credential_id")).workspace_id

  test "trace 12: the sign-out waits for the login to be verified; the app's switch ends nothing, the seat's criterion.passed does (300 s)" do
    assert_equal [ [ "signed_out", 300, "seat_event" ] ], summary(times(run_trace("12-signed-out-hold-verify-no-rules")))
  end

  test "trace 13: the limit while the next login is signed out ends at the continuing run's criterion.started (220 s)" do
    assert_equal [ [ "limit", 220, "seat_event" ] ], summary(times(run_trace("13-limit-next-signed-out-no-rules")))
  end

  test "trace 14: each start is paired on its own; Verify's sign-out starts nothing; a cancelled task's is not recovered" do
    list = times(run_trace("14-handoff-edges-no-rules"))
    assert_equal [
      [ "limit", 60, "seat_event" ], [ "limit", nil, "not_recovered" ], [ "limit", 0, "handoff" ], [ "limit", 0, "handoff" ],
      [ "limit", 0, "handoff" ], [ "limit", 100, "seat_event" ], [ "limit", 0, "handoff" ], [ "signed_out", 250, "seat_event" ]
    ], summary(list)
    not_recovered = list.fetch(1)
    assert_nil not_recovered.fetch("ended_at")
    reviews = list.last(2).map { |item| item.fetch("review_id") }
    assert(reviews.all?, "the reviewers' starts name their reviews")
    assert_equal list.first(6).map { |item| item.fetch("review_id") }, [ nil ] * 6
  end

  test "a task's list holds only that task's recovery times" do
    runner = run_trace("14-handoff-edges-no-rules")
    all = times(runner)
    tasks = Task.where(workspace_id: runner.workspace_id).order(:created_at).to_a
    by_task = tasks.map { |task| times(runner, task_id: task.id) }
    assert_equal all.size, by_task.sum(&:size)
    assert_equal [ 2, 3, 3 ], by_task.map(&:size)
  end

  # --- what ends it, and what does not (test 11) --------------------------------------

  test "a heartbeat and a read between the start and the end change nothing; the seat's next event ends it" do
    runner = run_trace("12-signed-out-hold-verify-no-rules", 10)
    task = Task.find_by!(workspace_id: runner.workspace_id)
    builder = Seat.find_by!(workspace_id: runner.workspace_id, role: "builder")
    open = times(runner, now: Time.current + 3600).sole
    assert_nil open.fetch("ended_by")
    assert_nil open.fetch("ended_at")

    seq = Event.where(workspace_id: runner.workspace_id).maximum(:seq)
    assert apply(runner, "heartbeat", builder, "id" => task.id).completed?
    Leverage::Reads::TaskPage.call(runner.workspace_id, task.id)
    Leverage::Reads::NextItem.call(builder)
    assert_equal seq, Event.where(workspace_id: runner.workspace_id).maximum(:seq), "a heartbeat and a read write no event"
    assert_nil times(runner).sole.fetch("ended_by")

    criterion = Criterion.find_by!(task_id: task.id, state: "started")
    outcome = apply(runner, "pass_criterion", builder, "id" => task.id, "cid" => criterion.id,
      "evidence" => { "kind" => "link", "value" => "https://example.test/work/recovery" })
    assert outcome.completed?
    ended = times(runner).sole
    assert_equal "seat_event", ended.fetch("ended_by")
    passed = Event.where(task_id: task.id, type: "criterion.passed").order(:seq).last
    assert_equal passed.effective_at.utc.iso8601(6), ended.fetch("ended_at")
  end

  test "an open one is measured to the time of the read, and has no end" do
    runner = run_trace("12-signed-out-hold-verify-no-rules", 8)
    start = Event.find_by!(workspace_id: runner.workspace_id, type: "credential.signed_out")
    item = times(runner, now: start.effective_at + 125.4).sole
    assert_equal [ "signed_out", 126, nil ], [ item.fetch("kind"), item.fetch("seconds"), item.fetch("ended_by") ]
    assert_nil item.fetch("ended_at")
    assert_equal start.effective_at.utc.iso8601(6), item.fetch("started_at")
  end

  test "a sign-out found by Verify (no seat) starts nothing" do
    scenario = Scenario.new
    credential = scenario.credential
    task = scenario.task(state: "working", builder: scenario.seat(credential: credential))
    scenario.sign_out_credential(credential, task: task)
    assert_empty Leverage::Reads::RecoveryTimes.call(scenario.workspace_id)
  end

  test "a start whose task is done or cancelled before any end is not recovered" do
    scenario = Scenario.new
    credential = scenario.credential
    builder = scenario.seat(credential: credential)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(credential, seat: builder, task: task)
    scenario.append("task.cancelled", task: task, actor_kind: "owner", actor_id: scenario.owner.id)
    item = Leverage::Reads::RecoveryTimes.call(scenario.workspace_id).sole
    assert_equal [ "limit", nil, "not_recovered" ], summary([ item ]).first
    assert_nil item.fetch("ended_at")
  end

  test "every item has the shape of openapi.json's RecoveryTime" do
    schema = Leverage::Contract.openapi.dig("components", "schemas", "RecoveryTime")
    runner = run_trace("14-handoff-edges-no-rules")
    times(runner).each do |item|
      assert_equal schema.fetch("required").sort, item.keys.sort
      assert_includes schema.dig("properties", "ended_by", "enum"), item.fetch("ended_by")
      assert_includes schema.dig("properties", "kind", "enum"), item.fetch("kind")
    end
  end

  # --- bin/rails leverage:recovery_times (HE-18) ----------------------------------------

  def recovery_times(workspace_id, **env)
    Rails.application.load_tasks unless Rake::Task.task_defined?("leverage:recovery_times")
    task = Rake::Task["leverage:recovery_times"]
    task.reenable
    names = %w[WORKSPACE_ID CEILING_SECONDS OPEN]
    saved = names.to_h { |name| [ name, ENV.fetch(name, nil) ] }
    names.each { |name| ENV[name] = nil }
    ENV["WORKSPACE_ID"] = workspace_id
    env.each { |name, value| ENV[name.to_s] = value }
    error = nil
    out, err = capture_io do
      task.invoke
    rescue SystemExit => exit
      error = exit
    end
    [ out + err, error.nil? || error.success? ]
  ensure
    saved&.each { |name, value| ENV[name] = value }
  end

  test "with a bar, each interval is printed beside it, and one longer than the bar fails" do
    runner = run_trace("11-limit-handoff-no-rules")
    out, passed = recovery_times(runner.workspace_id, CEILING_SECONDS: "900")
    refute passed, out
    assert_match(/0 s .*bar 900 s/, out)
    assert_match(/1600 s .*bar 900 s.*longer/, out)

    out, passed = recovery_times(runner.workspace_id, CEILING_SECONDS: "1600")
    assert passed, out
  end

  test "with no bar, it says no ceiling is set and compares nothing; the workspace's ceiling is the bar when set" do
    runner = run_trace("11-limit-handoff-no-rules")
    out, passed = recovery_times(runner.workspace_id)
    assert passed, out
    assert_match(/no recovery time ceiling is set/i, out)
    assert_match(/1600 s/, out)
    refute_match(/bar/, out)

    Workspace.find(runner.workspace_id).update_columns(recovery_time_ceiling_seconds: 1000)
    out, passed = recovery_times(runner.workspace_id)
    refute passed, out
    assert_match(/bar 1000 s/, out)
  end

  test "OPEN=fail also fails on an open interval; without it an open one passes" do
    runner = run_trace("12-signed-out-hold-verify-no-rules", 8)
    out, passed = recovery_times(runner.workspace_id)
    assert passed, out
    assert_match(/open/, out)

    out, passed = recovery_times(runner.workspace_id, OPEN: "fail")
    refute passed, out
  end

  test "an unknown workspace fails" do
    out, passed = recovery_times(SecureRandom.uuid)
    refute passed
    assert_match(/no such workspace/, out)
  end
end
