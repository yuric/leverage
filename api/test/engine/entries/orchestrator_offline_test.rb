require "test_helper"
require_relative "job_timers_support"

# The orchestrator_offline timer (PRD L401, L402; timers.json;
# state_machine.json; needs_you.json; milestone 4 plan §2.1 "The
# orchestrator's presence and its item", RD-15 to RD-20, SM-39, RC-37;
# traces 07 and 19): a workspace timer the sweep fires on every run.
#
# - It opens the workspace's one Orchestrator offline item when the
#   orchestrator is not online and a check waits (a rule_check job queued,
#   or a check held with check_error), effective at the later of the time
#   the role went offline and the time the oldest check began to wait. Its
#   facts: the role, the count then, and the account that is the cause.
# - It resolves the item when the orchestrator is online again, at the time
#   it came back. Then every errored check gets a new attempt, but an
#   errored check at task.before_claim, whose hold only closes (RC-37); a
#   check still queued keeps its job (RD-19).
# - It writes nothing while nothing changes, and never opens an item for
#   the planner (RD-20).
class OrchestratorOfflineTest < ActiveSupport::TestCase
  include JobTimersSupport

  attr_reader :scenario

  setup { @scenario = Scenario.new }

  def item = InboxItem.where(workspace_id: scenario.workspace_id, kind: "orchestrator_offline").order(:opened_at).last

  # A check whose model attempt has waited in the queue since seconds_ago.
  def waiting_check(seconds_ago, **options)
    _task, check, = pending_check(**options)
    since = scenario.database_now - seconds_ago
    latest_attempt(check).update_columns(queued_at: since)
    job_of(check).update_columns(queued_at: since)
    [ check, since ]
  end

  # A check that ended in error and holds its task with check_error, as the
  # second miss leaves it (trace 07, command 5); item: whether the task's
  # Check could not run item opened (only while the orchestrator was
  # online, SM-39). hook: the check's hook. Returns [check, hold].
  def errored_check(item: false, hook: nil, task_state: "backlog", command: "complete_contract")
    task, check, = pending_check(attempts: 2, hook: hook, task_state: task_state, command: command)
    job = job_of(check)
    job.update!(state: "timed_out")
    check.update!(result: "error")
    hold = ActiveRecord::Base.transaction do
      Leverage::Holds.open(scenario.context, task: task, reason: "check_error", rule_id: check.rule_id, item: item,
        facts: { rule_id: check.rule_id, rule_check_id: check.id })
    end
    [ check, hold ]
  end

  def open_item
    with_writers { timer("orchestrator_offline") }
    assert item&.state == "open", "the item is open"
    item
  end

  test "trace 07, command 3: no orchestrator has polled for 90 seconds and a check waits: the item opens" do
    orchestrator = orchestrator_polled(270)
    waiting_check(200)
    before = last_seq

    outcome = nil
    with_writers { outcome = timer("orchestrator_offline") }

    assert outcome.completed?
    events = events_after(before)
    assert_equal %w[inbox.opened], events.map(&:type)
    opened = events.sole
    assert_equal [ "inbox_item", item.id, nil, nil, nil ],
      [ opened.subject_kind, opened.subject_id, opened.task_id, opened.project_id, opened.cause_id ]
    assert_equal({ "kind" => "orchestrator_offline" }, opened.payload)
    assert_by_app_at events, orchestrator.last_polled_at + 90
    assert_equal [ "orchestrator_offline", "workspace", nil, nil, [], "open" ],
      [ item.kind, item.about_kind, item.about_id, item.hold_id, item.choices, item.state ]
    assert_equal({ "role" => "orchestrator", "waiting_checks" => 1, "credential_id" => nil }, item.facts)
  end

  test "trace 19, command 29: effective when the oldest check began to wait, when that came after the role went offline" do
    orchestrator_polled(600)
    _check, since = waiting_check(30)
    waiting_check(20)
    before = last_seq

    with_writers { timer("orchestrator_offline") }

    assert_by_app_at events_after(before), since
    assert_equal 2, item&.facts&.fetch("waiting_checks")
  end

  test "it is not opened while nothing waits: no check, or a check already claimed" do
    orchestrator_polled(600)
    pending_check(started: true, checker: scenario.orchestrator)
    scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"))
    before = last_seq

    with_writers { timer("orchestrator_offline") }

    assert_equal before, last_seq
    assert_nil item
  end

  test "it opens when no orchestrator seat exists at all (RD-16)" do
    _check, since = waiting_check(40)
    before = last_seq

    with_writers { timer("orchestrator_offline") }

    assert_by_app_at events_after(before), since
    assert_equal "open", item&.state
  end

  test "it is not opened twice: a run that finds it open writes nothing" do
    orchestrator_polled(600)
    waiting_check(200)
    open_item
    before = last_seq

    with_writers { timer("orchestrator_offline") }

    assert_equal before, last_seq
    assert_equal 1, InboxItem.where(workspace_id: scenario.workspace_id, kind: "orchestrator_offline").count
  end

  test "a check held with check_error waits too, and is counted" do
    orchestrator_polled(600)
    errored_check

    open_item

    assert_equal 1, item&.facts&.fetch("waiting_checks")
  end

  test "it names the account when every orchestrator seat's own account is the cause" do
    own = scenario.credential(provider: "codex")
    seat = scenario.orchestrator(credential: own)
    seat.update_columns(last_polled_at: scenario.database_now - 5)
    own.update_columns(limited_since: scenario.database_now - 50, limited_until: scenario.database_now + 3600)
    _check, since = waiting_check(100)
    before = last_seq

    with_writers { timer("orchestrator_offline") }

    assert_equal own.id, item&.facts&.fetch("credential_id")
    assert_by_app_at events_after(before), own.reload.limited_since
    refute_operator since, :>, own.limited_since
  end

  test "it never opens an item while the orchestrator is online, nor for the planner (RD-20)" do
    orchestrator_polled(10)
    waiting_check(200)
    planner = scenario.planner
    planner.update_columns(last_polled_at: scenario.database_now - 600)
    scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"))
    before = last_seq

    with_writers { timer("orchestrator_offline") }

    assert_equal before, last_seq
    assert_nil item
  end

  test "trace 07, command 7: when the orchestrator polls again the item resolves at the poll's time, whatever still waits" do
    orchestrator = orchestrator_polled(600)
    waiting_check(200)
    open_item
    orchestrator.update_columns(last_polled_at: scenario.database_now - 3)
    before = last_seq

    calls = with_writers { timer("orchestrator_offline") }

    assert_empty calls, "a check still queued keeps its job and its timers (RD-19)"
    events = events_after(before)
    assert_equal %w[inbox.resolved], events.map(&:type)
    assert_equal [ item.id, { "choice" => nil } ], [ events.sole.subject_id, events.sole.payload ]
    assert_by_app_at events, orchestrator.reload.last_polled_at
    assert_equal [ "resolved", "app", nil ], [ item.state, item.resolved_by_kind, item.resolved_by_id ]
  end

  test "an account that reset after the seat's last poll brings it back at the reset" do
    own = scenario.credential(provider: "codex")
    seat = scenario.orchestrator(credential: own)
    seat.update_columns(last_polled_at: scenario.database_now - 5)
    own.update_columns(limited_since: scenario.database_now - 50, limited_until: scenario.database_now + 3600)
    waiting_check(100)
    open_item
    own.update_columns(limited_until: scenario.database_now - 1)
    before = last_seq

    with_writers { timer("orchestrator_offline") }

    assert_by_app_at events_after(before), own.reload.limited_until
  end

  test "trace 19, command 31: on return an errored check gets a new attempt, as the app, at the time the role came back" do
    orchestrator = orchestrator_polled(600)
    check, hold = errored_check
    errored_job = job_of(check)
    open_item
    orchestrator.update_columns(last_polled_at: scenario.database_now - 2)
    before = last_seq

    calls = with_writers { timer("orchestrator_offline") }

    assert_equal [ "Jobs.queue", "RuleChecks.new_attempt" ], calls.map(&:name)
    queued = calls.first.keywords
    assert_equal [ "rule_check", check.task_id, check.id, "orchestrator", errored_job.input ],
      [ queued.fetch(:kind), queued.fetch(:task).id, queued.fetch(:target).id, queued.fetch(:seat_role), queued.fetch(:input) ]
    assert_equal check.id, calls.last.arguments.second.id
    events = events_after(before)
    assert_equal %w[inbox.resolved job.queued check.queued].sort, events.map(&:type).sort
    assert_equal "inbox.resolved", events.first.type
    assert_by_app_at events, orchestrator.reload.last_polled_at
    assert_nil hold.reload.closed_at, "the hold closes when the new attempt's result arrives (L403)"
  end

  test "on return an errored claim check only loses its hold (RC-37, L392)" do
    orchestrator = orchestrator_polled(600)
    check, hold = errored_check(hook: "task.before_claim", task_state: "ready", command: "claim")
    open_item
    orchestrator.update_columns(last_polled_at: scenario.database_now - 2)
    before = last_seq

    calls = with_writers { timer("orchestrator_offline") }

    assert_empty calls, "nothing is queued: no claim is left for it to complete"
    events = events_after(before)
    assert_equal %w[inbox.resolved hold.closed], events.map(&:type)
    assert_equal hold.id, events.last.subject_id
    assert_equal check.task_id, events.last.task_id
    assert_by_app_at events, orchestrator.reload.last_polled_at
    assert hold.reload.closed_at
  end

  test "an errored check whose task item opened stays with the owner while the orchestrator stays online" do
    orchestrator_polled(10)
    _with_item, = errored_check(item: true)
    without_item, = errored_check(item: false)
    before = last_seq

    calls = with_writers { timer("orchestrator_offline") }

    assert_equal [ "Jobs.queue", "RuleChecks.new_attempt" ], calls.map(&:name),
      "only the check that erred while the orchestrator was offline, with no item of its own, is queued again"
    assert_equal without_item.id, calls.last.arguments.second.id
    refute(events_after(before).any? { |event| event.type.start_with?("inbox.") })
    assert_empty(with_writers { timer("orchestrator_offline") }, "queued again once: the check waits for its result")
  end
end
