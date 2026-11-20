require "test_helper"
require_relative "provider_world"
require_relative "entries/handoff_support"
require_relative "../support/walk"

# The database clock can step back. Docker Desktop's virtual machine on a
# Mac was seen reading clock_timestamp() 0.59 ms earlier than a moment
# before, and the suite then wrote a step that closed before it opened. The
# product's times do not follow it back (PRD L219: at never decreases as
# seq grows; L120 and L220: effective_at never decreases within a task;
# L825: no step has a negative duration): the time a command takes under
# the workspace lock is never earlier than the at of the workspace's last
# event, and an event a workspace timer writes on a task never takes
# effect before that task's last event. These tests make the clock the
# lock reads (WorkspaceLock.clock) answer an earlier time.
class ClockStepBackTest < ActiveSupport::TestCase
  include HandoffSupport

  T = Leverage::Transitions

  def last_event(workspace_id) = Event.where(workspace_id: workspace_id).order(:seq).last

  # Runs the block with WorkspaceLock.clock answering reading's value
  # (called each time when it is a lambda), and puts the clock back.
  def with_clock(reading)
    lock = Leverage::WorkspaceLock
    original = lock.method(:clock)
    lock.define_singleton_method(:clock) { reading.respond_to?(:call) ? reading.call : reading }
    yield
  ensure
    lock.define_singleton_method(:clock, original)
  end

  # Runs the block with the clock the lock reads answering seconds before
  # the workspace's last event.
  def clock_back(workspace_id, seconds, &)
    with_clock(last_event(workspace_id).at - seconds, &)
  end

  test "the time the lock gives is later than the workspace's last event, by a microsecond when the clock reads earlier" do
    use_scenario
    scenario.task(state: "ready")
    last = last_event(scenario.workspace_id)

    _workspace, at = clock_back(scenario.workspace_id, 0.040) { Leverage::WorkspaceLock.take(scenario.workspace_id) }

    assert_equal last.at + Rational(1, 1_000_000), at, "the clock read 40 ms back and the command took that time"
  end

  test "a command sent while the clock reads earlier writes after the last event, and its step does not close early" do
    use_scenario(lease_length_seconds: 600)
    builder = scenario.seat(role: "builder", credential: scenario.credential)
    task = scenario.task(state: "ready")
    before = last_event(scenario.workspace_id)

    outcome = nil
    clock_back(scenario.workspace_id, 0.040) do
      assert_nothing_raised do # no step that closes before it opened (CHECK task_steps_no_negative_duration)
        outcome = T.apply(T::Request.new(command: "claim", workspace_id: scenario.workspace_id, caller_kind: "seat",
          caller_id: builder.id, key: new_key, request_hash: "claim", params: {}))
      end
    end

    assert outcome.completed?, outcome.inspect
    claimed = last_event(scenario.workspace_id)
    assert_equal "task.claimed", claimed.type
    assert_operator claimed.at, :>, before.at, "at went back as seq grew (L219), or two commands share one"
    assert_operator task.reload.lease_due_at, :>=, before.at + 600, "the lease runs from a time before the last event"
    assert_empty TaskStep.where(task_id: task.id).where("closed_at < opened_at").to_a
  end

  test "a workspace timer given a time before a task's last event writes on that task no earlier than it" do
    use_scenario
    rule = scenario.with_shipped_rules.find { |each| each.key == "different_provider_review" }
    claude = scenario.credential(provider: "claude")
    builder = scenario.seat(role: "builder", credential: claude)
    task = scenario.task(state: "in_review", builder: builder)
    scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude"))
    Leverage::Gating.implementation = ProviderWorld.for(rule)
    latest = Event.where(task_id: task.id).maximum(:effective_at)

    # The sweep reads the clock, then waits for the lock while a command
    # writes on the task; the time it read is now before that write.
    written = events_written do
      Leverage::Timers.apply_workspace(scenario.workspace_id, "reviewer_eligibility", at: latest - 1)
    end

    opened = written.find { |event| event.type == "inbox.opened" && event.task_id == task.id }
    assert opened, written.map(&:type).inspect
    assert_operator opened.effective_at, :>=, latest, "the task's effective times went back (L120, L220)"
  end

  # The step partition test's walks under a clock that steps back by up to
  # 50 ms at each command: the log audit holds the steps (they touch end to
  # end, none is negative, they sum to the lifetime) and the times. Before
  # the fix 28 of 41 such walks failed: a step that closed before it
  # opened, a task's effective times going back.
  SEEDS = (801..808)

  SEEDS.each do |seed|
    test "walk seed #{seed} holds its steps, replay and audit while the clock steps back" do
      random = Random.new(seed)
      # Whole microseconds, as the database's clock reads.
      jittery = -> { (Workspace.connection.select_value("SELECT clock_timestamp()") - (random.rand * 0.050)).round(6) }
      walk = with_clock(jittery) { Walk.new(seed: seed, steps: 100).run }

      assert_empty Leverage::Replay.diff(walk.workspace_id), walk.to_s
      assert_empty Leverage::LogAudit.call(walk.workspace_id), walk.to_s
    end
  end
end
