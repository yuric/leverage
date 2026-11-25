require "test_helper"
require_relative "entries/gated_flow_support"

# GA-3 and GA-6: a check the only General seats cannot take must stop after
# two misses. Polling while a check is held must not start the cycle again.
class GeneralOrchestratorPresenceTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup { use_scenario }

  test "a General seat's own draft cannot start repeated offline notifications" do
    scenario.with_shipped_rules
    general = scenario.seat(role: "general")
    task = scenario.task(criteria: [], project: scenario.project)
    draft = assert_completed(owner_command("draft_contract", { "id" => task.id }))
    claim = assert_completed(claim_job(general))
    assert_equal draft.result.fetch("job_id"), claim.result.fetch("job_id")

    # The draft result runs Complete contract, which puts the promotion
    # behind the shipped task.before_ready gate.
    assert_equal :pending, submit_result(general, Job.find(claim.result.fetch("job_id")), contract_body).outcome
    rule = Rule.find_by!(workspace_id: scenario.workspace_id, key: "specific_details")
    check = RuleCheck.find_by!(task_id: task.id, rule_id: rule.id)

    assert_stays_in_error(check, [ general ])
  end

  test "a General seat's own added task cannot start repeated offline notifications" do
    scenario.with_shipped_rules
    general = scenario.seat(role: "general")
    body = contract_body.slice("title", "details", "criteria")
    assert_equal :pending, seat_command(general, "add_task", body).outcome
    task_id = Event.find_by!(workspace_id: scenario.workspace_id, type: "task.created", actor_id: general.id).task_id
    rule = Rule.find_by!(workspace_id: scenario.workspace_id, key: "specific_details")
    check = RuleCheck.find_by!(task_id: task_id, rule_id: rule.id)

    assert_stays_in_error(check, [ general ])
    assert_equal "backlog", Task.find(task_id).state
  end

  test "two General seats cannot start repeated offline notifications while a review pass waits on a check" do
    builder = scenario.seat(role: "general")
    reviewer = scenario.seat(role: "general", provider: "codex")
    rule = model_rule(hook: "task.before_done")
    task = scenario.task(state: "in_review", builder: builder)
    review = scenario.review(task, reviewer: reviewer)
    assert_completed(seat_command(reviewer, "acknowledge_review_briefing", { "id" => review.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: reviewer, review: review) }))
    assert_equal :pending, seat_command(reviewer, "pass_review", pass_body(review)).outcome
    check = RuleCheck.find_by!(task_id: task.id, rule_id: rule.id)

    assert_stays_in_error(check, [ builder, reviewer ])
    assert_equal "pending", PendingTransition.find(check.pending_transition_id).state
    assert_equal reviewer.id, review.reload.reviewer_seat_id
  end

  private

  # Feed the watcher the same cursor it sends on its next poll. Every item
  # of this kind delivered through the cursor is one notification input.
  def assert_stays_in_error(check, seats)
    start = scenario.database_now + 1
    cursor = scenario.workspace.reload.last_seq
    notifications = []
    online_at = []
    with_sweep_clock do
      0.step(1800, 60) do |elapsed|
        @sweep_at = start + elapsed
        seats.each { |seat| seat.update_columns(last_polled_at: @sweep_at) }
        Leverage::Sweep.sweep_workspace(scenario.workspace_id)
        online_at << elapsed if Leverage::RolePresence.online?(scenario.workspace, "orchestrator", @sweep_at)
        page = Leverage::Reads::Inbox.call(scenario.workspace_id, after_seq: cursor)
        notifications.concat(page.fetch(:items).select { |item| item.fetch(:kind) == "orchestrator_offline" })
        cursor = page.fetch(:next_after_seq)
      end
    end

    opened = Event.where(workspace_id: scenario.workspace_id, type: "inbox.opened")
      .where("payload->>'kind' = ?", "orchestrator_offline")
    first_error = Event.where(subject_id: check.id, type: "check.finished").where("payload->>'result' = ?", "error").order(:seq).first!
    after_error = Event.where(task_id: check.task_id).where("seq > ?", first_error.seq)
    requeued = after_error.where(type: %w[check.queued job.queued]).order(:seq).pluck(:type)
    assert_equal [ 1, 1, [] ], [ opened.count, notifications.size, requeued ],
      "workspace openings, notification inputs, and queue events after the first error"
    assert_empty online_at, "the orchestrator must count offline throughout"
    assert_equal "error", check.reload.result
    hold = Hold.find_by!(rule_check_id: check.id, reason: "check_error", closed_at: nil)
    refute InboxItem.exists?(hold_id: hold.id), "the role never returned to open a task item"
    assert_equal [ "open", 1 ], InboxItem.find(opened.sole.subject_id).then { |item| [ item.state, item.facts.fetch("waiting_checks") ] }
    assert_equal 1, Leverage::Reads::SystemHealth.waiting_checks(scenario.workspace_id)
  end

  # Sweep and the workspace lock use the database clock independently.
  # The real sweep, timer commands, gates and event writers stay in use.
  def with_sweep_clock
    readers = { Leverage::Sweep => :database_now, Leverage::WorkspaceLock => :clock }
    saved = readers.to_h { |mod, name| [ mod, mod.method(name) ] }
    clock = -> { @sweep_at }
    readers.each { |mod, name| mod.define_singleton_method(name) { clock.call } }
    yield
  ensure
    readers.each { |mod, name| mod.define_singleton_method(name, saved.fetch(mod)) }
  end
end
