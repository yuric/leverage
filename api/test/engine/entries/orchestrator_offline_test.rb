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
#   it came back. An eligible errored check gets a new attempt. An
#   errored check at task.before_claim only loses its hold (RC-37); a
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
  # An errored claim check has already lapsed its provisional claim
  # (L392): its transition is no longer pending.
  def errored_check(item: false, hook: nil, task_state: "backlog", command: "complete_contract")
    task, check, pending = pending_check(attempts: 2, hook: hook, task_state: task_state, command: command)
    pending.update!(state: "cancelled", params: nil) if command == "claim"
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
    # About the workspace, by its id: InboxItem.about_id is a required uuid
    # in openapi.json, and the Mac's InboxItem cannot read a null one.
    assert_equal [ "orchestrator_offline", "workspace", scenario.workspace_id, nil, [], "open" ],
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
    _check, since = waiting_check(0)
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
    orchestrator.update_columns(last_polled_at: scenario.database_now)
    before = last_seq

    calls = with_writers { timer("orchestrator_offline") }

    assert_equal [ "RuleChecks.queue_attempt" ], calls.map(&:name)
    assert_equal [ check.id, { seat_role: "orchestrator" } ], [ calls.sole.arguments.second.id, calls.sole.keywords ]
    events = events_after(before)
    assert_equal %w[inbox.resolved check.queued job.queued], events.map(&:type)
    fresh = Job.where(target_id: check.id).order(:attempt_number).last
    assert_equal [ 3, fresh.id ], [ events.second.payload["attempt_number"], events.second.payload["job_id"] ],
      "the check's third attempt, on a job of its own"
    refute_equal errored_job.id, fresh.id
    assert_by_app_at events, orchestrator.reload.last_polled_at
    assert_nil hold.reload.closed_at, "the hold closes when the new attempt's result arrives (L403)"
  end

  test "on return an errored claim check only loses its hold (RC-37, L392)" do
    orchestrator = orchestrator_polled(600)
    check, hold = errored_check(hook: "task.before_claim", task_state: "ready", command: "claim")
    open_item
    orchestrator.update_columns(last_polled_at: scenario.database_now)
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

  [ 1, 2 ].each do |seat_count|
    test "return through #{seat_count} General seats requeues both eligible errored checks" do
      checks = Array.new(2) { errored_check.first }
      offline = open_item
      seat_count.times { scenario.seat(role: "general", last_polled_at: scenario.database_now) }

      with_writers { timer("orchestrator_offline") }

      assert_equal "resolved", offline.reload.state
      assert_equal [ 3, 3 ], checks.map { |check| job_of(check).attempt_number }
      assert_equal [ nil, nil ], checks.map { |check| check.reload.result }
      refute InboxItem.exists?(workspace_id: scenario.workspace_id, kind: "check_could_not_run", state: "open")
    end
  end

  test "an already queued check does not prevent General retrying another check" do
    errored, = errored_check
    offline = open_item
    queued, = waiting_check(5)
    queued_job = job_of(queued)
    scenario.seat(role: "general", last_polled_at: scenario.database_now)

    with_writers { timer("orchestrator_offline") }

    assert_equal "resolved", offline.reload.state
    assert_equal [ queued_job.id, "queued" ], [ job_of(queued).id, queued_job.reload.state ]
    assert_equal 3, job_of(errored).attempt_number
    assert_nil errored.reload.result
    refute InboxItem.exists?(workspace_id: scenario.workspace_id, kind: "check_could_not_run", state: "open")
  end

  test "General presence closes all errored claim holds even when a seat built one of their tasks" do
    checks = Array.new(2) { errored_check(hook: "task.before_claim", task_state: "ready", command: "claim") }
    offline = open_item
    general = scenario.seat(role: "general", last_polled_at: scenario.database_now)
    barred = checks.first.first
    scenario.append("task.claimed", task: Task.find(barred.task_id), actor_kind: "seat", actor_id: general.id,
      payload: { seat_id: general.id, credential_id: nil, model: general.model })

    calls = with_writers { timer("orchestrator_offline") }

    assert_equal "resolved", offline.reload.state
    assert_empty calls
    assert checks.all? { |_, hold| hold.reload.closed_at }
    assert_equal [ 2, 2 ], checks.map { |check, _| job_of(check).attempt_number }
    refute InboxItem.exists?(workspace_id: scenario.workspace_id, kind: "check_could_not_run", state: "open")
  end

  test "a hold that names its check is read by that check, not by its rule's latest one" do
    orchestrator_polled(600)
    check, hold = errored_check
    hold.update_columns(rule_check_id: check.id)
    newer = scenario.rule_check(Task.find(check.task_id), rule: Rule.find(check.rule_id), round: 1)
    newer.update_columns(updated_at: check.updated_at + 1)

    open_item

    assert_equal 2, item&.facts&.fetch("waiting_checks"), "the errored check held, and the newer one queued"
  end

  test "an errored check whose task item opened stays with the owner while the orchestrator stays online" do
    orchestrator_polled(10)
    _with_item, = errored_check(item: true)
    without_item, = errored_check(item: false)
    before = last_seq

    calls = with_writers { timer("orchestrator_offline") }

    assert_equal [ "RuleChecks.queue_attempt" ], calls.map(&:name),
      "only the check that erred while the orchestrator was offline, with no item of its own, is queued again"
    assert_equal without_item.id, calls.sole.arguments.second.id
    refute(events_after(before).any? { |event| event.type.start_with?("inbox.") })
    assert_empty(with_writers { timer("orchestrator_offline") }, "queued again once: the check waits for its result")
  end

  test "on return through a General seat, an errored check it cannot claim gets an owner item while a claimable one is queued" do
    app_rule = scenario.rule(hook: "task.before_ready", checker: "app", checker_function: "minimum_criteria_count")
    decided = scenario.rule_check(scenario.task, rule: app_rule, result: "passed")
    RuleCheckAttempt.find_by!(rule_check_id: decided.id).update_columns(queued_at: scenario.database_now - 600)
    claimable, claimable_hold = errored_check
    barred, barred_hold = errored_check
    general = scenario.seat(role: "general")
    scenario.append("task.claimed", task: Task.find(barred.task_id), actor_kind: "seat", actor_id: general.id,
      payload: { seat_id: general.id, credential_id: nil, model: general.model })
    open_item
    general.update_columns(last_polled_at: scenario.database_now)
    before = last_seq

    timer("orchestrator_offline")

    assert_equal "resolved", item.reload.state
    assert_equal %w[inbox.resolved check.queued job.queued inbox.opened], events_after(before).map(&:type)
    assert_nil claimable.reload.result
    assert_equal 3, job_of(claimable).attempt_number
    assert_nil claimable_hold.reload.closed_at
    assert_equal "error", barred.reload.result
    assert_equal 2, job_of(barred).attempt_number
    assert_nil barred_hold.reload.closed_at
    owner_item = InboxItem.find_by!(hold_id: barred_hold.id, state: "open")
    assert_equal [ "check_could_not_run", %w[override_once run_again turn_rule_off], barred.id ],
      [ owner_item.kind, owner_item.choices.sort, owner_item.facts.fetch("rule_check_id") ]
    assert_equal "hold.opened", Event.find(events_after(before).last.cause_id).type
  end
end
