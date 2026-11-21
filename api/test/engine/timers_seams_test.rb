require "test_helper"

# The methods of timers.rb that milestone 4's packages build against while
# WP7 changes the rest of the file (milestone 4 plan §4, the hand-over
# table; §0.1 fact 6; WP7 owns this file afterwards):
#
# - Timers.apply_workspace(workspace, name, at:) runs a workspace timer, or
#   the app's install_shipped_rules, through the path the sweep uses
#   (Sweep.timer): as the app, with no key, and with at as the effective
#   time of what it writes (never later than the command's own clock).
# - Timers.job_due_at(job, kind) is a job's queue or run due time, from the
#   sources timers.json names.
# - Timers.timer_command? answers for every timer of timers.json, so a
#   pending timer's own command applies no task timer first.
class TimersSeamsTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  Timers = Leverage::Timers

  # Writes one event with the context's defaults only.
  class WritesOne < Leverage::Transitions::Entry
    def perform(ctx)
      ctx.emit("rule.disabled", subject_kind: "rule", subject_id: ctx.request.params.fetch("rule_id", SecureRandom.uuid),
        payload: {})
      @result = nil
    end
  end

  setup { @scenario = Scenario.new }

  def events = Event.where(workspace_id: @scenario.workspace_id).order(:seq)

  def fields(event) = [ event.type, event.actor_kind, event.actor_id, event.command_id, event.subject_kind, event.payload ]

  test "apply_workspace has its final arguments" do
    assert_equal [ [ :req, :workspace ], [ :req, :name ], [ :keyreq, :at ] ], Timers.method(:apply_workspace).parameters
    assert_equal [ [ :req, :job ], [ :req, :kind ] ], Timers.method(:job_due_at).parameters
  end

  test "a workspace timer applied through apply_workspace writes what the sweep writes, at the given time" do
    T::Table.with_entries("orchestrator_offline" => WritesOne) do
      Leverage::Sweep.timer(@scenario.workspace_id, "orchestrator_offline")
      swept = events.last
      given = @scenario.database_now - 30
      outcome = Timers.apply_workspace(@scenario.workspace, "orchestrator_offline", at: given)
      applied = events.last

      assert outcome.completed?
      refute_equal swept.id, applied.id
      assert_equal fields(swept), fields(applied)
      assert_equal [ "app", nil, nil ], [ applied.actor_kind, applied.actor_id, applied.command_id ]
      assert_equal given, applied.effective_at
      assert_operator applied.at, :>, given, "at is the command's own clock, read under the lock"
      assert_equal swept.at, swept.effective_at
    end
  end

  test "it takes a workspace's id as well as its row, and stores no commands row" do
    T::Table.with_entries("reviewer_eligibility" => WritesOne) do
      before = Command.count
      given = @scenario.database_now - 5
      Timers.apply_workspace(@scenario.workspace_id, "reviewer_eligibility", at: given)

      assert_equal given, events.last.effective_at
      assert_equal before, Command.count
    end
  end

  test "a time later than the command's clock is the command's clock" do
    T::Table.with_entries("orchestrator_offline" => WritesOne) do
      Timers.apply_workspace(@scenario.workspace, "orchestrator_offline", at: @scenario.database_now + 3600)
      event = events.last

      assert_equal event.at, event.effective_at
    end
  end

  test "a merged workspace timer runs through it as through the sweep" do
    outcome = Timers.apply_workspace(@scenario.workspace, "seat_run_placement", at: @scenario.database_now)

    assert outcome.completed?
    assert_equal Leverage::Sweep.timer(@scenario.workspace_id, "seat_run_placement"), outcome
    assert_empty events.where(type: %w[rule.disabled]).to_a
  end

  test "it runs only the workspace timers and the app's own commands, never a task timer or a caller's command" do
    assert_equal %w[command_key_retention install_shipped_rules orchestrator_offline reviewer_eligibility seat_run_placement usage_read_due],
      Timers::WORKSPACE_COMMANDS.sort
    %w[builder_lease_expiry check_queue_timeout add_task claim made_up_timer].each do |name|
      assert_raises(ArgumentError, name) { Timers.apply_workspace(@scenario.workspace, name, at: @scenario.database_now) }
    end
  end

  test "timer_command? answers for every timer of timers.json, the Table's eleven among them" do
    names = Leverage::Contract.timers.fetch("timers").map { |timer| timer.fetch("timer") }
    names.each { |name| assert Timers.timer_command?(name), name }
    T::Table::TIMERS.each { |name| assert Timers.timer_command?(name), name }
    %w[add_task claim install_shipped_rules].each { |name| refute Timers.timer_command?(name), name }
  end

  # --- job_due_at -------------------------------------------------------------

  def check_with_job(version_fields: {}, started: false)
    rule = @scenario.rule(hook: "task.before_ready", **version_fields)
    task = @scenario.task(state: "backlog")
    check = @scenario.rule_check(task, rule: rule, started: started)
    [ check, RuleCheckAttempt.find_by!(rule_check_id: check.id), Job.find(RuleCheckAttempt.find_by!(rule_check_id: check.id).job_id) ]
  end

  test "a rule check's queue due time is its attempt's queued time plus the workspace's queue timeout" do
    _check, attempt, job = check_with_job

    assert_equal attempt.queued_at + 120, Timers.job_due_at(job, :queue)
    assert_nil Timers.job_due_at(job, :run), "not started: no run due time"
  end

  test "a rule version's own timeouts win over the workspace's" do
    _check, attempt, job = check_with_job(version_fields: { queue_timeout_seconds: 30, run_timeout_seconds: 45 }, started: true)

    assert_equal attempt.queued_at + 30, Timers.job_due_at(job, :queue)
    assert_equal attempt.started_at + 45, Timers.job_due_at(job, :run)
  end

  test "a started rule check's run due time is its attempt's start plus the workspace's run timeout" do
    @scenario.workspace.update!(check_run_timeout_seconds: 200)
    _check, attempt, job = check_with_job(started: true)

    assert_equal attempt.started_at + 200, Timers.job_due_at(job, :run)
  end

  test "a draft job's due times are its own queued and claimed times plus the workspace's timeouts" do
    task = @scenario.task(state: "backlog")
    queued = @scenario.job(kind: "contract_draft", task: task)
    claimed = @scenario.job(kind: "contract_draft", task: @scenario.task(state: "backlog"), state: "claimed",
      seat: @scenario.seat(role: "planner"))

    assert_equal queued.queued_at + 120, Timers.job_due_at(queued, :queue)
    assert_nil Timers.job_due_at(queued, :run)
    assert_equal claimed.claimed_at + 300, Timers.job_due_at(claimed, :run)
  end

  test "a kind other than :queue or :run is refused" do
    job = @scenario.job(kind: "contract_draft", task: @scenario.task(state: "backlog"))
    assert_raises(ArgumentError) { Timers.job_due_at(job, :lease) }
  end
end
