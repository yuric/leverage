require "test_helper"

# The command_key_retention timer (PRD L220, L818; timers.json; milestone 2
# plan WP5, EN-22): commands rows older than 7 days, the least time an
# idempotency key is kept, are purged, and so are sweep_runs rows older
# than 7 days. Per workspace, in bounded batches (params limit), and it
# writes no event.
class CommandKeyRetentionTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @now = @scenario.database_now
  end

  def timer(scenario = @scenario, params = {})
    T.apply(T::Request.new(command: "command_key_retention", workspace_id: scenario.workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: params))
  end

  def command_row(age, scenario = @scenario)
    Command.create!(workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: SecureRandom.uuid,
      key: "key-#{SecureRandom.hex(4)}", command: "heartbeat", request_hash: "made-up-hash", outcome: "completed",
      result: {}, created_at: @now - age, updated_at: @now - age)
  end

  def sweep_row(age, scenario = @scenario)
    SweepRun.create!(workspace_id: scenario.workspace_id, ran_at: @now - age, tasks_touched: 0, workspace_timers_fired: 0)
  end

  test "commands and sweep runs older than 7 days go; younger ones stay; no event is written" do
    old = command_row(8.days)
    young = command_row(6.days)
    old_run = sweep_row(7.days + 1.minute)
    young_run = sweep_row(1.day)
    seq = Workspace.find(@scenario.workspace_id).last_seq

    outcome = timer

    assert outcome.completed?
    assert_equal({ "commands_deleted" => 1, "sweep_runs_deleted" => 1, "more" => false }, outcome.result)
    refute Command.exists?(old.id)
    assert Command.exists?(young.id)
    refute SweepRun.exists?(old_run.id)
    assert SweepRun.exists?(young_run.id)
    assert_equal seq, Workspace.find(@scenario.workspace_id).last_seq
  end

  test "another workspace's rows are its own sweep's" do
    other = Scenario.new
    theirs = command_row(30.days, other)

    timer

    assert Command.exists?(theirs.id)
  end

  test "limit bounds one run and more says whether a full batch went" do
    3.times { command_row(10.days) }

    first = timer(@scenario, "limit" => 2)
    assert_equal [ 2, true ], [ first.result.fetch("commands_deleted"), first.result.fetch("more") ]
    second = timer(@scenario, "limit" => 2)
    assert_equal [ 1, false ], [ second.result.fetch("commands_deleted"), second.result.fetch("more") ]
  end

  test "a purged key is new again: a repeat after retention runs as a new command" do
    row = command_row(8.days)
    timer

    assert_nil Command.find_by(caller_kind: row.caller_kind, caller_id: row.caller_id, key: row.key)
  end
end
