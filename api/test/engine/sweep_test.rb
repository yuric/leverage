require "test_helper"
require_relative "entries/job_timers_support"

# The sweep (PRD L118, L404, L822; timers.json trigger; milestone 2 plan
# WP5, EN-22): it applies due task timers to tasks no command has touched,
# through the same entries a command applies first, purges old command
# keys, and records one sweep_runs row per workspace per run. It is not a
# timer and writes no event of its own.
#
# Milestone 3 (its plan, WP4, HD-4, HE-23): the sweep also releases the
# credential holds that are due on tasks no command has touched, and fires
# the workspace timer seat_run_placement once on every run. Their entries
# are WP3's and WP5's; the tests here stand in for them with entries of
# their own, called the way the sweep calls the real ones.
#
# Milestone 4 (its plan, WP7): the sweep also applies the check and draft
# timers to jobs no command has touched, and fires the two workspace timers
# of milestone 4, orchestrator_offline and reviewer_eligibility (WP9's
# entry), on every run through Timers.apply_workspace. Milestone 6 adds
# usage_read_due to every run (CR-10), bringing the count to four workspace
# timers, or five when the run also purges command keys.
module SweepTestEntries
  # Closes a due credential hold, as WP3's credential_hold_release does
  # when the sweep runs it with params limit.
  class HoldRelease < Leverage::Transitions::Entry
    def load(ctx)
      @tasks = Leverage::Timers.due_credential_holds(ctx.workspace.id, ctx.at, %w[working],
        limit: Integer(ctx.request.params.fetch("limit", 100)))
    end

    def perform(ctx)
      released = @tasks.select { |task| Leverage::Timers.credential_hold_due?(task, ctx.at) }
      released.each do |task|
        Leverage::Holds.close(ctx, hold: Leverage::Timers.credential_hold(task), task: task,
          effective_at: Leverage::Timers.credential_hold_effective_at(task), command_id: nil, actor_kind: "app", actor_id: nil)
      end
      @result = { "released_task_ids" => released.map(&:id) }
    end
  end

  # Counts the runs of seat_run_placement, by workspace.
  class Placement < Leverage::Transitions::Entry
    RUNS = Hash.new(0)

    def perform(ctx)
      RUNS[ctx.workspace.id] += 1
      @result = nil
    end
  end
end

class SweepTest < ActiveSupport::TestCase
  S = Leverage::Sweep
  E = SweepTestEntries

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
    assert_equal 4, run.workspace_timers_fired
    assert_operator run.ran_at, :>=, due
  end

  test "a run with nothing due still records itself and writes no event" do
    @scenario.task(state: "working")
    seq = Workspace.find(@scenario.workspace_id).last_seq

    S.sweep_workspace(@scenario.workspace_id)

    assert_equal [ 0, 4 ], [ runs.sole.tasks_touched, runs.sole.workspace_timers_fired ]
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
    assert_equal 5, runs.sole.workspace_timers_fired
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

  # PRD principle 3 (L217): the first statement of every transaction that
  # changes anything takes the workspace lock. The sweep_runs row is a
  # change too: it is written in a transaction of its own that first locks
  # the workspace, and ran_at is that lock's clock reading.
  test "the sweep_runs row is written under the workspace lock" do
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << [ payload[:name], payload[:sql] ] unless payload[:name] == "SCHEMA"
    end
    begin
      S.sweep_workspace(@scenario.workspace_id)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    insert = seen.rindex { |_name, sql| sql.match?(/\AINSERT INTO "sweep_runs"/) }
    assert insert, seen.map(&:last).inspect
    opened = seen[0...insert].rindex { |name, sql| name == "TRANSACTION" && sql.match?(/\A(BEGIN|SAVEPOINT)/) }
    assert opened, "the insert runs in a transaction of its own"
    inside = seen[(opened + 1)...insert].map(&:last)
    assert_match(/\ASELECT .*FROM "workspaces" WHERE "workspaces"\."id" = .* FOR UPDATE\z/m, inside.first.to_s,
      "the transaction's first statement locks the workspace")
    assert_equal "SELECT clock_timestamp()", inside.second
  end

  # --- Milestone 3 ---------------------------------------------------------

  def with_handoff_timers(&block)
    Leverage::Transitions::Table.with_entries("credential_hold_release" => E::HoldRelease,
      "seat_run_placement" => E::Placement, &block)
  end

  # A Working task whose builder's own credential stopped, held with
  # credential_limit, the hold due at the reset (returned).
  def held_task(reset_at: :now)
    own = @scenario.limit_credential(@scenario.credential, reset_at: nil)
    task = @scenario.task(state: "working", builder: @scenario.seat(role: "builder", credential: own))
    hold = @scenario.hold(task, reason: "credential_limit", credential: own, item: false)
    reset = reset_at == :now ? @scenario.database_now : reset_at
    own.update!(limited_until: reset)
    [ task, hold, reset ]
  end

  test "it releases an untouched credential hold at its due time and counts the task" do
    task, hold, reset = held_task
    _, waiting, = held_task(reset_at: @scenario.database_now + 3600)

    with_handoff_timers { S.sweep_workspace(@scenario.workspace_id) }

    closed = Event.where(workspace_id: @scenario.workspace_id, type: "hold.closed").sole
    assert_equal [ hold.id, task.id, reset, "app", nil ],
      [ closed.subject_id, closed.task_id, closed.effective_at, closed.actor_kind, closed.command_id ]
    assert_nil waiting.reload.closed_at, "a hold not yet due stays open"
    assert_equal 1, runs.sole.tasks_touched
  end

  test "it works through more due credential holds than one batch holds" do
    held = 3.times.map { held_task }

    with_handoff_timers { S.sweep_workspace(@scenario.workspace_id, batch: 2) }

    assert(held.all? { |_task, hold, _reset| hold.reload.closed_at })
    assert_equal 3, runs.sole.tasks_touched
  end

  test "a credential hold due before its task's lease closes first; the lease ends after it" do
    task, hold, reset = held_task
    lease_due = @scenario.database_now
    @scenario.make_due(task, at: lease_due)

    with_handoff_timers { S.sweep_workspace(@scenario.workspace_id) }

    events = Event.where(task_id: task.id, type: %w[hold.closed task.lease_expired]).order(:seq)
    assert_equal [ [ "hold.closed", reset ], [ "task.lease_expired", lease_due ] ], events.map { |e| [ e.type, e.effective_at ] }
    assert hold.reload.closed_at
  end

  test "a credential hold whose task's lease is due first is left to the lease, which closes it" do
    task, hold, = held_task(reset_at: @scenario.database_now + 3600)
    lease_due = @scenario.database_now
    @scenario.make_due(task, at: lease_due)
    Credential.find(hold.credential_id).update!(limited_until: @scenario.database_now)

    with_handoff_timers { S.sweep_workspace(@scenario.workspace_id) }

    events = Event.where(task_id: task.id, type: %w[hold.closed task.lease_expired]).order(:seq)
    assert_equal %w[task.lease_expired hold.closed], events.map(&:type)
    assert_equal [ lease_due ], events.map(&:effective_at).uniq
    assert hold.reload.closed_at
  end

  test "it fires seat_run_placement once on every run of every workspace" do
    other = Scenario.new
    E::Placement::RUNS.clear

    with_handoff_timers do
      S.sweep_workspace(@scenario.workspace_id)
      S.sweep_workspace(@scenario.workspace_id)
      S.sweep_workspace(other.workspace_id)
    end

    assert_equal 2, E::Placement::RUNS[@scenario.workspace_id]
    assert_equal 1, E::Placement::RUNS[other.workspace_id]
    assert_equal [ 4, 4 ], runs.map(&:workspace_timers_fired)
  end

  # --- Milestone 4 ---------------------------------------------------------

  include JobTimersSupport

  def scenario = @scenario

  test "it fires orchestrator_offline, reviewer_eligibility and usage_read_due through Timers.apply_workspace" do
    started = @scenario.database_now

    calls = spy_on(Leverage::Timers, :apply_workspace) { S.sweep_workspace(@scenario.workspace_id) }

    expected = %w[orchestrator_offline reviewer_eligibility usage_read_due]
    assert_equal expected.map { |name| [ @scenario.workspace_id, name ] }, calls.map(&:arguments)
    calls.each do |call|
      assert_operator call.keywords.fetch(:at), :>=, started
      assert_operator call.keywords.fetch(:at), :<=, runs.sole.ran_at
    end
  end

  test "an offline orchestrator's item opens in the run that finds a check waiting" do
    orchestrator_polled(600)
    pending_check

    with_writers { S.sweep_workspace(@scenario.workspace_id) }

    assert InboxItem.exists?(workspace_id: @scenario.workspace_id, kind: "orchestrator_offline", state: "open")
  end

  test "it times out an untouched check and an untouched draft at their due times and counts their tasks" do
    _task, check, = pending_check
    check_due = make_queue_due(check)
    draft = @scenario.job(kind: "contract_draft", task: @scenario.task(state: "backlog"), state: "claimed",
      seat: @scenario.planner)
    draft_due = make_job_due(draft, :run)

    with_writers { S.sweep_workspace(@scenario.workspace_id) }

    timed_out = Event.where(workspace_id: @scenario.workspace_id, type: "job.timed_out").order(:seq)
    assert_equal [ [ job_of_attempt(check, 1), check_due.to_f ], [ draft.id, draft_due.to_f ] ],
      timed_out.map { |event| [ event.subject_id, event.effective_at.to_f ] }
    assert_equal 2, runs.sole.tasks_touched
  end

  test "a check due before its task's lease times out first; one due after it waits for the lease to end" do
    early_task, early = working_task_with_check
    make_queue_due(early)
    @scenario.make_due(early_task)
    late_task, late = working_task_with_check
    @scenario.make_due(late_task)
    make_queue_due(late)

    with_writers { S.sweep_workspace(@scenario.workspace_id) }

    order = ->(task) { Event.where(task_id: task.id, type: %w[job.timed_out task.lease_expired]).order(:seq).map(&:type) }
    assert_equal %w[job.timed_out task.lease_expired], order.call(early_task)
    assert_equal %w[task.lease_expired job.timed_out], order.call(late_task)
    [ early_task, late_task ].each do |task|
      times = Event.where(task_id: task.id).order(:seq).map(&:effective_at)
      assert_equal times.sort, times, "effective times never go backwards within a task (L120)"
    end
  end

  # --- Milestone 6 ---------------------------------------------------------

  test "a sweep without command key purging schedules a due usage read" do
    credential = @scenario.credential
    @scenario.live_helper

    S.sweep_workspace(@scenario.workspace_id, purge: false)

    requests = HelperRequest.where(workspace_id: @scenario.workspace_id, kind: "read_usage")
    assert_equal [ [ credential.id, "queued" ] ], requests.pluck(:credential_id, :state)
  end

  def job_of_attempt(check, number) = RuleCheckAttempt.find_by!(rule_check_id: check.id, attempt_number: number).job_id
end
