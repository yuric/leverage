require "test_helper"
require_relative "../support/trace_runner"

# Track F's queries on golden-trace logs (PRD L322, L898; milestone 4 plan
# RT-7): a task's steps, read by Reads::TaskTimeline, with the seconds
# worked out by hand from the trace's times. The engine runs a trace on
# its own clock (EN-18), so a trace's @t:s is the instant the runner bound
# it to, and a length of the trace (@t:a to @t:b) is the engine's length
# between those two instants (TraceRunner#instant).
class TaskTimelineQueryTest < ActiveSupport::TestCase
  T = Leverage::Reads::TaskTimeline

  def run_trace(name)
    TraceRunner.new(name).run.tap { |runner| assert_empty runner.failures, runner.failures.join("\n") }
  end

  # The engine's seconds for the trace's @t:from to @t:to.
  def span(runner, from, to) = (runner.instant(to).to_r - runner.instant(from).to_r).to_f

  def task(runner, number)
    Task.where(workspace_id: runner.workspace_id).order(:created_at, :id).to_a.fetch(number - 1)
  end

  def assert_steps(runner, task, expected, as_of: nil)
    steps = T.call(runner.workspace_id, task.id, as_of: as_of)
    assert_equal expected.map(&:first), steps.map { |step| step.fetch(:kind) }
    expected.zip(steps).each do |(kind, from, to), step|
      assert_in_delta span(runner, from, to), step.fetch(:seconds), 0.000_001, kind
    end
    steps
  end

  # Trace 07: Complete contract at 10 waits on the specific-details check
  # until it errs at 250 (240 s), the owner holds it under check_error
  # until the override at 400 (150 s), and it is Ready since (100 s to the
  # sweep at 500).
  test "trace 07: the check step is 240 s, the wait for the owner 150, and the steps sum to the lifetime" do
    runner = run_trace("07-pending-gate-check-error-override")
    steps = assert_steps(runner, task(runner, 1),
      [ [ "wait_contract", 0, 10 ], [ "check", 10, 250 ], [ "wait_owner", 250, 400 ], [ "wait_ready", 400, 500 ] ],
      as_of: runner.instant(500))
    assert_in_delta span(runner, 0, 500), T.lifetime_seconds(steps), 0.000_001
  end

  # Trace 16: task 1 waits on the check twice (10 to 50, then 100 to 140)
  # around contract_incomplete's wait for the contract (50 to 100), and is
  # Ready until it is cancelled at 400; task 2's planner drafts it from 220
  # to 300, the check runs to 340, and it is Ready until 410.
  test "trace 16: the check, contract_incomplete's wait and the planner's draft, to the cancels" do
    runner = run_trace("16-model-gate-and-draft")
    first = assert_steps(runner, task(runner, 1),
      [ [ "wait_contract", 0, 10 ], [ "check", 10, 50 ], [ "wait_contract", 50, 100 ], [ "check", 100, 140 ],
        [ "wait_ready", 140, 400 ] ])
    second = assert_steps(runner, task(runner, 2),
      [ [ "wait_contract", 200, 220 ], [ "draft", 220, 300 ], [ "check", 300, 340 ], [ "wait_ready", 340, 410 ] ])
    assert_in_delta span(runner, 0, 400), T.lifetime_seconds(first), 0.000_001
    assert_in_delta span(runner, 200, 410), T.lifetime_seconds(second), 0.000_001
  end

  # L898: the steps sum to the lifetime, exactly, on every log a golden
  # trace makes: a task's life from its task.created to its end, or to the
  # time asked.
  WHOLE = Dir[Rails.root.join("contract/traces/*.json")].map { |path| File.basename(path, ".json") }.sort.select do |name|
    Leverage::Contract.trace(name).fetch("commands").all? do |command|
      Leverage::Transitions::Table.entry_for(command.fetch("command"))
    rescue Leverage::Transitions::Table::UnknownCommand
      false
    end
  end.freeze

  WHOLE.each do |name|
    test "trace #{name}: every task's steps sum exactly to its lifetime" do
      runner = run_trace(name)
      as_of = Task.connection.select_value("SELECT clock_timestamp()")
      Task.where(workspace_id: runner.workspace_id).find_each do |row|
        events = Event.where(task_id: row.id, type: %w[task.created task.done task.cancelled]).order(:seq)
        created = events.find { |event| event.type == "task.created" }.effective_at
        ended = events.find { |event| event.type != "task.created" }&.effective_at || as_of
        steps = T.call(runner.workspace_id, row.id, as_of: as_of)
        assert_equal (ended.to_r - created.to_r).to_f.round(6), T.lifetime_seconds(steps).round(6), "task #{row.id}"
      end
    end
  end
end
