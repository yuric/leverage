require "test_helper"

# The sweep (PRD L118, L404, L822; timers.json trigger; milestone 2 plan
# WP5, EN-22): it applies due task timers to tasks no command has touched,
# through the same entries a command applies first, purges old command
# keys, and records one sweep_runs row per workspace per run. It is not a
# timer and writes no event of its own.
class SweepTest < ActiveSupport::TestCase
  S = Leverage::Sweep

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
  end

  def runs = SweepRun.where(workspace_id: @scenario.workspace_id).order(:ran_at).to_a

  test "it ends an untouched builder lease and an untouched review lease and records the run" do
    task = @scenario.task(state: "working")
    review = @scenario.review(@scenario.task(state: "in_review"))
    @scenario.task(state: "working")
    due = @scenario.database_now
    @scenario.make_due(task, at: due)
    @scenario.make_due(review, at: due)

    S.sweep_workspace(@scenario.workspace_id)

    assert_equal "ready", task.reload.state
    assert_nil review.reload.reviewer_seat_id
    expired = Event.where(workspace_id: @scenario.workspace_id, type: %w[task.lease_expired review.lease_expired])
    assert_equal 2, expired.count
    expired.each { |event| assert_in_delta due.to_f, event.effective_at.to_f, 0.000_001 }

    run = runs.sole
    assert_equal 2, run.tasks_touched
    assert_equal 0, run.workspace_timers_fired, "no purge was asked for"
    assert_operator run.ran_at, :>=, due
  end

  test "a run with nothing due still records itself and writes no event" do
    @scenario.task(state: "working")
    seq = Workspace.find(@scenario.workspace_id).last_seq

    S.sweep_workspace(@scenario.workspace_id)

    assert_equal [ 0, 0 ], [ runs.sole.tasks_touched, runs.sole.workspace_timers_fired ]
    assert_equal seq, Workspace.find(@scenario.workspace_id).last_seq
  end

  test "a paused lease is left alone" do
    task = @scenario.task(state: "working")
    task.update_columns(lease_due_at: @scenario.database_now - 3600, lease_time_left_while_paused: 60)

    S.sweep_workspace(@scenario.workspace_id)

    assert_equal "working", task.reload.state
    assert_equal 0, runs.sole.tasks_touched
  end

  test "it works through more due leases than one batch holds" do
    now = @scenario.database_now
    tasks = 5.times.map { |index| @scenario.make_due(@scenario.task(state: "working"), at: now - 10 + index) }

    S.sweep_workspace(@scenario.workspace_id, batch: 2)

    assert(tasks.all? { |task| task.reload.state == "ready" })
    assert_equal 5, runs.sole.tasks_touched
  end

  test "a purging run purges old command keys and old sweep runs and counts the workspace timer" do
    now = @scenario.database_now
    old = Command.create!(workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: SecureRandom.uuid,
      key: "old-key", command: "heartbeat", request_hash: "made-up-hash", outcome: "completed", result: {},
      created_at: now - 8.days, updated_at: now - 8.days)
    old_run = SweepRun.create!(workspace_id: @scenario.workspace_id, ran_at: now - 8.days, tasks_touched: 0,
      workspace_timers_fired: 0)

    S.sweep_workspace(@scenario.workspace_id, purge: true, batch: 1)

    refute Command.exists?(old.id)
    refute SweepRun.exists?(old_run.id)
    assert_equal 1, runs.sole.workspace_timers_fired
  end

  test "pass sweeps every workspace and says how many" do
    other = Scenario.new
    task = other.make_due(other.task(state: "working"))

    count = S.pass

    assert_operator count, :>=, 2
    assert_equal "ready", task.reload.state
    assert SweepRun.exists?(workspace_id: other.workspace_id)
    assert SweepRun.exists?(workspace_id: @scenario.workspace_id)
  end

  test "the loop runs a pass every interval until it is told to stop, purging at most once per purge interval" do
    passes = []
    clock = [ 0.0 ]
    stop = false
    sleeper = lambda do |seconds|
      clock[0] += seconds
      stop = true if passes.size >= 3
    end
    sweeper = Object.new
    sweeper.define_singleton_method(:pass) { |purge:| passes << purge }

    S.run(interval: 15, purge_every: 40, clock: -> { clock[0] }, sleeper: sleeper, stop: -> { stop }, sweeper: sweeper)

    assert_equal [ true, false, false ], passes, "the first pass purges; the next purge is due 40 s later"
  end

  test "a pass that fails is logged and the loop goes on" do
    calls = 0
    stop = false
    sweeper = Object.new
    sweeper.define_singleton_method(:pass) do |purge:|
      calls += 1
      raise "made-up failure" if calls == 1
    end
    sleeper = ->(_seconds) { stop = true if calls >= 2 }

    S.run(interval: 15, clock: -> { 0.0 }, sleeper: sleeper, stop: -> { stop }, sweeper: sweeper)

    assert_equal 2, calls
  end
end
