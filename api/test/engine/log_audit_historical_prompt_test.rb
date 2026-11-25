require "test_helper"
require_relative "entries/gated_flow_support"

# The log audit on a New prompt written before app round 2 (GA-17, UX-2),
# with the waiting command it ended built by the real pipeline: the seat's
# submits run through the gate, so the checks, the holds and the pending
# transition are the engine's own. Only the old command itself is written
# by hand, as the build before UX-2 wrote it. Every value is made up.
class LogAuditHistoricalPromptTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup do
    use_scenario
    @orchestrator = online_orchestrator
    @seat = scenario.seat(role: "builder")
    model_rule(hook: "task.before_submit")
    @task = ready_to_submit(@seat)
    @after = scenario.workspace.reload.last_seq
  end

  def submit_note(note)
    acknowledge(@seat, @task)
    seat_command(@seat, "submit", submit_body(@task, note: note))
  end

  # A fourth changed input in one round: the row is held at the re-run
  # limit, with no attempt, no job and no check.queued (RD-45).
  def hold_at_rerun_limit
    3.times do |run|
      assert_equal :pending, submit_note("Made-up note #{run}.").outcome
      answer_next(@orchestrator, FAILED)
    end
    assert_equal :pending, submit_note("Made-up note 3.").outcome
    hold = open_holds(@task).sole
    assert_equal "rerun_limit", hold.reason
    refute Event.exists?(workspace_id: scenario.workspace_id, type: "check.queued", subject_id: hold.rule_check_id)
    hold
  end

  # What issue_landing_prompt did before UX-2: its receipt, and the release
  # of the seat's Working task under its key (SeatRuns, removed by UX-3).
  # Returns the commands row and the events of the key.
  def old_new_prompt(seat)
    request = owner_request("issue_landing_prompt", { "id" => seat.id, "connection" => "http", "address" => "http://example.test" })
    receipt = Command.create!(workspace_id: request.workspace_id, caller_kind: request.caller_kind, caller_id: request.caller_id,
      command: request.command, key: request.key, request_hash: request.request_hash, outcome: "completed",
      result: { seat_id: seat.id, connection: "http" })
    Leverage::SeatRuns.release_working_task(scenario.context(request: request), seat, reason: "new_prompt")
    [ receipt, Event.where(workspace_id: scenario.workspace_id, command_id: request.key).order(:seq).to_a ]
  end

  def audit(after = @after) = Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)

  test "a New prompt that cancelled a submit held at the re-run limit passes the audit" do
    hold_at_rerun_limit
    receipt, events = old_new_prompt(@seat)

    assert_equal %w[check.finished hold.closed inbox.resolved task.released], events.map(&:type)
    assert_equal [ "withdrawn", "rerun_limit", "new_prompt" ],
      [ events.first.payload["result"], events.second.payload["reason"], events.last.payload["reason"] ]
    assert_empty audit
    receipt.destroy! # After the command key retention period.
    assert_empty audit
  end

  # UX-17: the audit cannot tell an old receipt from a new one, so what
  # the command writes now is held here and by its own tests.
  test "a landing prompt issued now writes no event, so the audit reads it without the old shape" do
    fresh = own_seat
    after = scenario.workspace.reload.last_seq
    key = new_key
    params = { "id" => fresh.id, "connection" => "http", "address" => "http://example.test" }
    assert_empty events_written { assert_completed(owner_command("issue_landing_prompt", params, key: key)) }
    receipt = Command.find_by!(workspace_id: scenario.workspace_id, key: key)
    assert_equal [ "issue_landing_prompt", fresh.id ], [ receipt.command, receipt.result["seat_id"] ]
    refute Leverage::LogAudit.historical_prompt_release?([], {}, receipt: receipt)
    assert_empty audit(after)

    assert_empty events_written { assert_refused("invalid_state", owner_command("issue_landing_prompt", params.merge("id" => @seat.id))) }
    assert_equal [ "working", @seat.id ], @task.reload.values_at(:state, :holder_seat_id)
    assert_empty audit(after)
  end

  test "the held row met again under a later submit does not hide the New prompt that withdrew it" do
    held = hold_at_rerun_limit
    receipt, = old_new_prompt(@seat)
    first = PendingTransition.find_by!(workspace_id: scenario.workspace_id, task_id: @task.id, state: "cancelled")

    assert_completed(seat_command(@seat, "claim"))
    assert_equal :pending, submit_note("Made-up note 3.").outcome
    again = open_holds(@task.reload).sole
    assert_equal [ "rerun_limit", held.rule_check_id ], [ again.reason, again.rule_check_id ]
    refute_equal first.id, RuleCheck.find(held.rule_check_id).pending_transition_id, "the row names the later submit now"

    assert_empty audit
    receipt.destroy!
    assert_empty audit
  end
end
