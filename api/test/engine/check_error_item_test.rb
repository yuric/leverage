require "test_helper"
require_relative "entries/gated_flow_support"

# A blocking check that ends in error while the orchestrator is online
# opens its "A check could not run" item (PRD L400), also when its
# check_error hold was opened while the orchestrator was offline and so
# has no item yet (SM-39). Once the item is open the owner decides: the
# orchestrator_offline timer does not queue the check again (milestone 4
# review, finding 3).
class CheckErrorItemTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup do
    use_scenario
    @orchestrator = online_orchestrator
    @builder = scenario.seat(role: "builder")
    @rule = model_rule(hook: "task.before_submit")
    @task = ready_to_submit(@builder)
    assert_equal :pending, seat_command(@builder, "submit", submit_body(@task)).outcome
    @check = RuleCheck.find_by!(task_id: @task.id, rule_id: @rule.id)
  end

  def go_offline = @orchestrator.update_columns(last_polled_at: scenario.database_now - 200)

  def come_back = @orchestrator.update_columns(last_polled_at: scenario.database_now)

  def attempts = RuleCheckAttempt.where(rule_check_id: @check.id).count

  def items = open_items(@task).select { |item| item.kind == "check_could_not_run" }

  test "an error while online opens the item at once" do
    error_check(@check)

    assert_equal [ "check_error" ], open_holds(@task).map(&:reason)
    assert_equal [ open_holds(@task).sole.id ], items.map(&:hold_id)
  end

  test "the log attributes a retry to orchestrator recovery before an offline item opens" do
    go_offline
    error_check(@check)
    assert_equal [ "check_error" ], open_holds(@task).map(&:reason)
    assert_empty InboxItem.where(workspace_id: scenario.workspace_id)
    before = scenario.workspace.reload.last_seq

    come_back
    assert_completed(timer("orchestrator_offline"))

    written = Event.where(workspace_id: scenario.workspace_id).where("seq > ?", before).order(:seq).to_a
    assert_equal %w[check.queued job.queued], written.map(&:type)
    assert_equal [ [ "app", nil ], [ "app", nil ] ], written.map { |event| [ event.actor_kind, event.command_id ] }
    assert_equal [ @check.id, written.last.subject_id ], [ written.first.subject_id, written.first.payload.fetch("job_id") ]
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: before)
  end

  test "an error while offline, the orchestrator back, and an error again while online opens the item" do
    go_offline
    error_check(@check)
    hold = open_holds(@task).sole
    assert_equal [ "check_error", [] ], [ hold.reason, items ]

    before = attempts
    come_back
    timer("orchestrator_offline")
    assert_equal before + 1, attempts, "the orchestrator's return queues the check again (RD-19)"
    assert_nil @check.reload.result

    error_check(@check)

    assert_equal [ hold.id ], open_holds(@task).map(&:id), "the same hold stays open"
    item = items.sole
    assert_equal hold.id, item.hold_id
    assert_equal({ "rule_id" => @rule.id, "rule_check_id" => @check.id }, item.facts)
    opened = Event.find_by!(workspace_id: scenario.workspace_id, type: "inbox.opened", subject_id: item.id)
    assert_equal [ "app", nil ], [ opened.actor_kind, opened.actor_id ]
    finished = Event.where(workspace_id: scenario.workspace_id, type: "check.finished", subject_id: @check.id)
      .order(:seq).last
    assert_equal finished.id, opened.cause_id

    after = attempts
    timer("orchestrator_offline")
    assert_equal after, attempts, "with its item open the check stays with the owner"
    assert_equal "error", @check.reload.result
  end

  # Finding 4: an errored blocking check holds the task at once, though
  # another blocking check of the same move still runs (the Holds table,
  # L163: "A blocking rule check ends in error"), so the lease pauses and
  # the item opens when the error is recorded.
  test "an error beside a check that still runs opens check_error at once and pauses the lease" do
    other = model_rule(hook: "task.before_submit", name: "Made-up second rule")
    task = ready_to_submit(scenario.seat(role: "builder"))
    assert_equal :pending, seat_command(task_builder(task), "submit", submit_body(task)).outcome
    first = RuleCheck.find_by!(task_id: task.id, rule_id: @rule.id)
    second = RuleCheck.find_by!(task_id: task.id, rule_id: other.id)
    refute_nil task.reload.lease_due_at

    error_check(first)

    assert_nil second.reload.result, "the other check still runs"
    hold = open_holds(task).sole
    assert_equal [ "check_error", first.id ], [ hold.reason, hold.rule_check_id ]
    assert_equal [ hold.id ], open_items(task).map(&:hold_id)
    task.reload
    assert_nil task.lease_due_at, "the lease is paused"
    refute_nil task.lease_time_left_while_paused
    assert_equal "working", task.state
  end

  test "at task.before_claim an error beside a check that still runs lapses the claim and withdraws the other" do
    erring = model_rule(hook: "task.before_claim", name: "Made-up claim rule")
    running = model_rule(hook: "task.before_claim", name: "Made-up second claim rule")
    task = scenario.task(state: "ready")
    claimant = scenario.seat(role: "builder")
    key = new_key
    assert_equal :pending, seat_command(claimant, "claim", {}, key: key).outcome
    first = RuleCheck.find_by!(task_id: task.id, rule_id: erring.id)
    second = RuleCheck.find_by!(task_id: task.id, rule_id: running.id)

    error_check(first)

    assert_equal [ "ready", nil ], [ task.reload.state, task.holder_seat_id ]
    assert_equal "withdrawn", second.reload.result
    assert_empty Job.where(workspace_id: scenario.workspace_id, target_id: second.id, state: %w[queued claimed])
    assert_equal [ [ "check_error", first.id ] ], open_holds(task).map { |hold| [ hold.reason, hold.rule_check_id ] }
    assert_equal [ "refused", "invalid_state" ], [ command_row(claimant, key).outcome, command_row(claimant, key).refusal["code"] ]
  end

  def task_builder(task) = Seat.find(task.holder_seat_id)
end
