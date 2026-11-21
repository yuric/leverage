require "test_helper"
require_relative "../support/trace_runner"
require_relative "../support/walk"

# The log audit (PRD L896 "every command ... wrote the events the table
# names for it, plus only the ... side events this PRD requires"; test 2's
# invariant on a real log): Leverage::LogAudit reads a workspace's events
# command by command, finds the command each group belongs to (its
# commands row, or the timer its events name), and lists every group whose
# events are not one of that command's state-table rows from the state the
# task was in, every refused command that wrote events of its own, and
# every task whose steps do not partition its life.
class LogAuditTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  test "releasing a lease after the last approved action was overturned leaves the stopped action" do
    walk = Walk.new(seed: 10_101, steps: 120).run
    events = Event.where(workspace_id: walk.workspace_id)
    overturned = events.where(type: "action.stopped").where("payload->>'overturned' = 'true'").order(:seq).last
    assert overturned, "the walk must overturn the approval"
    release = events.where(task_id: overturned.task_id, type: "task.released").where("seq > ?", overturned.seq).order(:seq).first
    assert release, "the builder must release the same task after the overturn"
    refute events.where(command_id: release.command_id, type: "hold.opened")
      .where("payload->>'reason' = 'action_unconfirmed'").exists?
    assert_empty Leverage::LogAudit.call(walk.workspace_id)
  end

  def run_trace(name)
    TraceRunner.new(name).run.tap { |runner| assert_empty runner.failures, runner.failures.join("\n") }
  end

  def audit(runner) = Leverage::LogAudit.call(runner.workspace_id, after_seq: runner.setup_seq)

  def key_of(runner, symbol) = Leverage::Contract::TraceBinder.new(start: Time.current).id(symbol)

  # Appends one event as if the command with this key wrote it later.
  def append_under(runner, key, type, task:, payload: {}, caller: nil, subject: nil)
    request = T::Request.new(command: "audit_test", workspace_id: runner.workspace_id, caller_kind: caller && "seat",
      caller_id: caller, key: key, request_hash: nil, params: {})
    ActiveRecord::Base.transaction(requires_new: true) do
      runner.scenario.context(request: request).emit(type, task: task, subject: subject, payload: payload)
    end
  end

  # Milestone 3's traces (its plan HT-1): the reports' rows, the credential
  # timer's events with no key, the side events of report_request_result
  # and change_seat (plan §2.3), and the owner's controls.
  %w[
    09-core-loop-no-rules 10-leases-no-rules 11-limit-handoff-no-rules 12-signed-out-hold-verify-no-rules
    13-limit-next-signed-out-no-rules 14-handoff-edges-no-rules 15-owner-controls-no-rules
  ].each do |name|
    test "the log of trace #{name} passes" do
      assert_empty audit(run_trace(name))
    end
  end

  # Milestone 4 (its plan RE-3, RT-4): a waiting command's own events under
  # its key in the command that brings the last result, rule check, job and
  # hold events beside a command's row, the job timers' and the workspace
  # timers' events with no key, and the one-time write of the shipped rules.
  %w[
    01-happy-path 02-failed-review-rework 05-limit-handoff 06-signed-out-hold-verify
    07-pending-gate-check-error-override 08-lease-expiry-and-cancel 16-model-gate-and-draft
    17-submit-rule-rerun-and-override 18-claim-gate-done-gate-and-ends 19-provider-rule-offline-and-jobs
  ].each do |name|
    test "the log of trace #{name}, with its rules, checks and jobs, passes" do
      assert_empty audit(run_trace(name))
    end
  end

  # RE-3's second key: a row's own events may be written under another
  # command's key only when a pending transition of that key exists.
  test "a move written later under a key that never waited is found" do
    runner = run_trace("16-model-gate-and-draft")
    key = key_of(runner, "$key:t1_complete_2")
    PendingTransition.where(workspace_id: runner.workspace_id, command_key: key).update_all(command_key: "made-up-key")
    found = audit(runner)
    assert(found.any? { |line| line.include?(key) && line.include?("never waited") }, found.inspect)
  end

  # RT-4: no task.ready, task.claimed, task.submitted or review.passed
  # whose command had, at its hook, an enabled blocking gate without a row
  # that passed, did not apply, was withdrawn or was overridden.
  test "a move past a blocking gate whose check did not pass is found" do
    runner = run_trace("16-model-gate-and-draft")
    key = key_of(runner, "$key:t1_complete_2")
    pending = PendingTransition.find_by!(workspace_id: runner.workspace_id, command_key: key)
    rule = Rule.find_by!(workspace_id: runner.workspace_id, key: "specific_details")
    check = RuleCheck.where(pending_transition_id: pending.id, rule_id: rule.id).sole
    check.update_columns(result: "failed")
    found = audit(runner)
    assert(found.any? { |line| line.include?("task.ready") && line.include?(check.rule_id) }, found.inspect)
  end

  test "a move past a blocking gate with no check at all is found" do
    runner = run_trace("01-happy-path")
    RuleCheckAttempt.where(workspace_id: runner.workspace_id).delete_all
    RuleCheck.where(workspace_id: runner.workspace_id).delete_all
    found = audit(runner)
    assert(found.any? { |line| line.include?("task.ready") && line.include?("gate") }, found.inspect)
  end

  test "approval before the same round's passing review is found" do
    scenario = Scenario.new
    task = scenario.finishing_task(holder: false, actions: [ { kind: "send", description: "Made-up send." } ])
    action = Action.find_by!(task_id: task.id)
    after = scenario.workspace.reload.last_seq
    scenario.append("action.approved", task: task, round: 1, subject: action, payload: { lease_seat_id: nil })

    found = Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
    assert(found.any? { |line| line.include?("action.approved") && line.include?("review.passed") }, found.inspect)
  end

  test "a passing check written after approval cannot clear the action's frozen gate" do
    scenario = Scenario.new
    rule = scenario.rule(hook: "action.requested")
    task = scenario.finishing_task(holder: false, actions: [ { kind: "send", description: "Made-up send." } ])
    action = Action.find_by!(task_id: task.id)
    after = scenario.workspace.reload.last_seq
    scenario.append("action.approved", task: task, subject: action, payload: { lease_seat_id: nil })
    scenario.rule_check(task, rule: rule, subject: action, result: "passed")

    found = Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
    assert(found.any? { |line| line.include?("action.approved") && line.include?(rule.id) }, found.inspect)
  end

  test "an override clears the frozen gate only for approvals written after it" do
    scenario = Scenario.new
    rule = scenario.rule(hook: "action.requested")
    task = scenario.finishing_task(holder: false, actions: [ { kind: "send", description: "Made-up send." } ])
    action = Action.find_by!(task_id: task.id)
    check = scenario.rule_check(task, rule: rule, subject: action, result: "failed")
    before = scenario.append("action.approved", task: task, subject: action, payload: { lease_seat_id: nil })
    scenario.append("check.overridden", task: task, subject: check, actor_kind: "owner", actor_id: scenario.owner.id)
    after = scenario.append("action.approved", task: task, subject: action, payload: { lease_seat_id: nil })

    gate_findings = Leverage::LogAudit.call(scenario.workspace_id, after_seq: before.seq - 1)
      .select { |line| line.include?("action.approved") && line.include?(rule.id) }
    assert_equal 1, gate_findings.size, gate_findings.inspect
    assert_match(/seq #{before.seq}: /, gate_findings.sole)
    refute_match(/seq #{after.seq}: /, gate_findings.sole)
  end

  test "start and report without approval and Done with an open action are found" do
    scenario = Scenario.new
    task = scenario.finishing_task(holder: false, actions: [
      { kind: "send", description: "Made-up send." }, { kind: "publish", description: "Made-up publish." }
    ])
    action = Action.where(task_id: task.id).order(:position).first
    after = scenario.workspace.reload.last_seq
    scenario.append("action.started", task: task, subject: action)
    scenario.append("action.reported_done", task: task, subject: action)
    scenario.append("task.done", task: task)

    found = Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
    %w[action.started action.reported_done].each do |type|
      assert(found.any? { |line| line.include?(type) && line.include?("action.approved") }, found.inspect)
    end
    assert(found.any? { |line| line.include?("task.done") && line.include?("unresolved action") }, found.inspect)
  end

  # RC-50, RD-12: review claim-next writes the provider rule's applied row
  # for the review it skips, on that review's task, and claims another.
  test "a review claim-next that skips one task's review and claims another's passes" do
    scenario = Scenario.new
    scenario.rule(key: "different_provider_review", origin: "shipped")
    claude = scenario.credential(provider: "claude")
    skipped = scenario.task(state: "in_review", builder: scenario.seat(credential: claude))
    taken = scenario.task(state: "in_review", builder: scenario.seat(credential: scenario.credential(provider: "codex")))
    reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "claude", name: "Another claude"))
    after = scenario.workspace.reload.last_seq
    outcome = T.apply(T::Request.new(command: "claim_review", workspace_id: scenario.workspace_id, caller_kind: "seat",
      caller_id: reviewer.id, key: "skip-and-claim", request_hash: "s" * 64, params: {}))

    assert outcome.completed?, outcome.refusal&.code
    written = Event.where(workspace_id: scenario.workspace_id).where("seq > ?", after).order(:seq)
    assert_equal [ [ "check.finished", skipped.id ], [ "review.started", taken.id ] ], written.pluck(:type, :task_id)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
  end

  # credential.switched is a side event in the registry, but only the rows
  # that name it may write it (milestone 3 plan §2.3 and WP9): the trace's
  # last command (pass_review, which ends the task) with a switch appended
  # in its own group, at its time and under its key, is found; trace 11's
  # reports and its timer, whose rows name the switch, pass.
  test "a credential.switched the command's row does not allow is found" do
    runner = run_trace("11-limit-handoff-no-rules")
    assert_empty audit(runner)
    last = Event.where(workspace_id: runner.workspace_id).order(:seq).last
    task = Task.find(last.task_id)
    seat = Seat.find_by!(workspace_id: runner.workspace_id, role: "reviewer")
    request = T::Request.new(command: "audit_test", workspace_id: runner.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: last.command_id, request_hash: nil, params: {})
    ActiveRecord::Base.transaction(requires_new: true) do
      runner.scenario.context(request: request, at: last.at).emit("credential.switched", task: task,
        subject: Credential.find(seat.credential_id), actor_kind: "app", actor_id: nil,
        payload: { from_credential_id: seat.credential_id, model: nil, seat_id: seat.id, review_id: nil, job_id: nil })
    end
    found = audit(runner)
    assert(found.any? { |line| line.include?(last.command_id) && line.include?("credential.switched") }, found.inspect)
  end

  # A command whose rows have no state may touch several tasks: a passed
  # Verify of a login closes the credential holds of every task it was
  # waiting for (report_request_result, plan §2.3).
  test "a Verify that closes the credential holds of two tasks in one command passes" do
    scenario = Scenario.new
    login = scenario.credential
    tasks = Array.new(2) { scenario.task(state: "working", builder: scenario.seat(credential: login)) }
    helper = scenario.helper
    call = lambda do |command, kind, caller, params|
      T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: kind, caller_id: caller,
        key: "audit-#{SecureRandom.hex(6)}", request_hash: "c" * 64, params: params)).tap { |outcome| assert outcome.completed? }
    end
    after = scenario.workspace.reload.last_seq
    tasks.each do |task|
      call.call("report_signed_out", "helper", helper.id, "id" => login.id, "credential_id" => login.id,
        "seat_id" => task.holder_seat_id, "task_id" => task.id, "review_id" => nil, "job_id" => nil,
        "observed_at" => (scenario.database_now - 1).utc.iso8601(6), "tool_version" => "0.0.0-made-up")
    end
    assert_equal 2, Hold.where(workspace_id: scenario.workspace_id, reason: "credential_signed_out", closed_at: nil).count
    request = call.call("verify_credential", "owner", scenario.owner.id, "id" => login.id).result.fetch("helper_request_id")
    call.call("report_request_result", "helper", helper.id, "id" => request, "result" => {
      "outcome" => "finished", "checks" => [ { "check" => "signed_in", "passed" => true, "failure" => nil } ],
      "tool_version" => "0.0.0-made-up", "plan" => nil, "account_email" => nil })
    closed = Event.where(workspace_id: scenario.workspace_id, type: "hold.closed").where("seq > ?", after)
    assert_equal 2, closed.distinct.count(:task_id)
    assert_equal 1, closed.distinct.count(:command_id)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
  end

  # Found by the walks (seed 460 of SEED=1): a sign-out a run reports may
  # leave another task's credential_limit hold with no due time and no
  # item, and opens "Account signed out" there (HE-11, plan §2.3): the
  # row's side event, on a task other than the report's own.
  test "a sign-out that opens Account signed out on another task's hold passes" do
    scenario = Scenario.new
    first = scenario.credential
    second = scenario.credential(provider: "codex")
    held = scenario.task(state: "working", builder: scenario.seat(credential: first))
    reporting = scenario.task(state: "working", builder: scenario.seat(credential: first))
    scenario.limit_credential(second)
    helper = scenario.helper
    report = lambda do |command, task, fields|
      params = { "id" => first.id, "credential_id" => first.id, "seat_id" => task.holder_seat_id, "task_id" => task.id,
                 "review_id" => nil, "job_id" => nil, "observed_at" => (scenario.database_now - 1).utc.iso8601(6),
                 "tool_version" => "0.0.0-made-up" }.merge(fields)
      T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "helper",
        caller_id: helper.id, key: "audit-#{SecureRandom.hex(6)}", request_hash: "d" * 64, params: params))
        .tap { |outcome| assert outcome.completed?, outcome.refusal&.code }
    end
    after = scenario.workspace.reload.last_seq
    report.call("report_limit", held, "window" => "five_hour",
      "reset_at" => (scenario.database_now + 3600).utc.iso8601(6))
    assert Hold.find_by(task_id: held.id, reason: "credential_limit", closed_at: nil)
    report.call("report_signed_out", reporting, {})

    signed_out = Event.find_by!(workspace_id: scenario.workspace_id, type: "credential.signed_out")
    written = Event.where(workspace_id: scenario.workspace_id, command_id: signed_out.command_id)
    assert_equal [ reporting.id, held.id ].sort, written.distinct.pluck(:task_id).sort
    assert written.exists?(task_id: held.id, type: "inbox.opened")
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
  end

  # One command may apply both timers of one task (Timers.apply_task_timers):
  # the credential hold, due first, closes and switches the account, then
  # the lease, past its due time too, ends. Both are timers' events with no
  # key, in one group: the release's and the lease end's are each matched to
  # their own timer (WP9's choice 4, met by walk seed 883 of SEED=1).
  test "a credential release and a lease end applied for one task in one command pass" do
    scenario = Scenario.new
    own = scenario.credential
    below = scenario.credential(provider: "codex")
    builder = scenario.seat(credential: own)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(below, reset_at: scenario.database_now + 7200)
    after = scenario.workspace.reload.last_seq
    params = { "id" => own.id, "credential_id" => own.id, "seat_id" => builder.id, "task_id" => task.id,
               "review_id" => nil, "job_id" => nil, "window" => "five_hour",
               "reset_at" => (scenario.database_now + 3600).utc.iso8601(6),
               "observed_at" => (scenario.database_now - 1).utc.iso8601(6), "tool_version" => "0.0.0-made-up" }
    outcome = T.apply(T::Request.new(command: "report_limit", workspace_id: scenario.workspace_id, caller_kind: "helper",
      caller_id: scenario.helper.id, key: "audit-#{SecureRandom.hex(6)}", request_hash: "e" * 64, params: params))
    assert outcome.completed?, outcome.refusal&.code
    assert Hold.find_by(task_id: task.id, reason: "credential_limit", closed_at: nil), "the hold waits for the reset"

    below.update_columns(limited_until: scenario.database_now - 2) # its reset passed: due at once, on that login
    scenario.make_due(task, at: scenario.database_now)
    assert_operator Leverage::Timers.credential_hold_due_at(task.reload), :<=, task.lease_due_at, "the hold is due first"
    T.apply(T::Request.new(command: "heartbeat", workspace_id: scenario.workspace_id, caller_kind: "seat",
      caller_id: builder.id, key: "audit-#{SecureRandom.hex(6)}", request_hash: "f" * 64, params: { "id" => task.id }))

    timers = Event.where(workspace_id: scenario.workspace_id, command_id: nil).where("seq > ?", after).order(:seq)
    assert_equal %w[hold.closed credential.switched task.lease_expired], timers.pluck(:type).first(3)
    assert_equal 1, timers.pluck(:at).uniq.size, "one command applied both timers"
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
  end

  # A timer's events have no key: the credential hold release (hold.closed,
  # credential.switched) is read as credential_hold_release, and the same
  # events as no timer writes them when no credential hold closes.
  test "events with no key that close a hold no timer closes are found" do
    runner = run_trace("15-owner-controls-no-rules")
    hold = Hold.find_by!(workspace_id: runner.workspace_id, reason: "owner_hold")
    append_under(runner, nil, "hold.closed", task: Task.find(hold.task_id), subject: hold,
      payload: { reason: "owner_hold", rule_id: nil, credential_id: nil, lease_seat_id: nil, wait_cause: nil })
    found = audit(runner)
    assert(found.any? { |line| line.include?("no command") || line.include?("no timer") }, found.inspect)
  end

  test "a timer and the action requests on either side of a keyed review are audited in sequence" do
    walk = Walk.new(seed: 1057, steps: 120).run
    requested = Event.where(workspace_id: walk.workspace_id, type: "action.requested").order(:seq).first!
    around = Event.where(workspace_id: walk.workspace_id, at: requested.at).order(:seq)
    earlier_timer = around.where(command_id: nil).where("seq < ?", requested.seq).first
    later_check = around.where(command_id: nil, type: "check.queued").where("seq > ?", requested.seq).first

    assert earlier_timer, "the command applies a due timer before passing the review"
    assert later_check, "passing the review queues an action check after action.requested"
    assert earlier_timer.seq < requested.seq && requested.seq < later_check.seq

    findings = Leverage::LogAudit.call(walk.workspace_id)
    assert_empty findings, findings.join("\n")
  end

  test "orchestrator recovery can close an errored claim's hold without a workspace item" do
    walk = Walk.new(seed: 632, steps: 120).run
    events = Event.where(workspace_id: walk.workspace_id)
    close = events.find_by!(seq: 100, type: "hold.closed")
    opened = events.find_by!(type: "hold.opened", subject_id: close.subject_id)
    check = events.where(type: "check.finished", subject_id: opened.payload.fetch("rule_check_id"))
      .where("seq < ?", close.seq).order(:seq).last!

    assert_nil close.command_id
    assert_equal "check_error", close.payload.fetch("reason")
    assert_equal %w[task.before_claim error], check.payload.values_at("hook", "result")
    assert_equal [ "hold.closed" ], events.where(at: close.at).order(:seq).pluck(:type)
    findings = Leverage::LogAudit.call(walk.workspace_id)
    assert_empty findings, findings.join("\n")
  end

  test "the log of a walk, every event of it written by a command, passes from its first event" do
    walk = Walk.new(seed: 21).run
    assert_empty Leverage::LogAudit.call(walk.workspace_id), walk.to_s
  end

  # IN-30: a new helper token treats every seat still marked running as
  # stopped, which releases a review such a seat holds (IF-21). The release
  # is the row's conditional event, as it is for report_run_stopped.
  test "a new helper token that releases a review held by a running seat passes" do
    scenario = Scenario.new
    reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "codex"), run_state: "running",
      wanted_running: true)
    task = scenario.task(state: "in_review")
    review = scenario.review(task, reviewer: reviewer)
    after = scenario.workspace.reload.last_seq
    outcome = T.apply(T::Request.new(command: "issue_helper_token", workspace_id: scenario.workspace_id,
      caller_kind: "owner", caller_id: scenario.owner.id, key: "audit-helper-token", request_hash: "made-up-hash",
      params: { "name" => "Made-up Mac" }))
    assert outcome.completed?
    assert_nil review.reload.reviewer_seat_id, "the review is released"
    assert_equal [ "review.released" ], Event.where(workspace_id: scenario.workspace_id).where("seq > ?", after).pluck(:type)
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
  end

  test "an event the command's row does not allow is found" do
    runner = run_trace("09-core-loop-no-rules")
    task = Task.find_by!(workspace_id: runner.workspace_id)
    key = key_of(runner, "$key:t1_claim_20")
    seat = Seat.find_by!(workspace_id: runner.workspace_id, role: "builder")
    append_under(runner, key, "task.briefing_acknowledged", task: task, caller: seat.id)
    found = audit(runner)
    assert(found.any? { |line| line.include?(key) && line.include?("claim") }, found.inspect)
  end

  test "a command that wrote fewer events than its row names is found" do
    only_contract = Class.new(T::Entry) do
      def load(ctx)
        @task = Task.find_by!(id: ctx.request.params["id"], workspace_id: ctx.workspace.id)
      end

      def perform(ctx)
        @task.update!(contract_version: 1)
        ctx.emit("task.contract_changed", task: @task, payload: { contract_version: 1, minimum_strength_rank: nil,
          added_criterion_ids: [], reset_criterion_ids: [], removed_criterion_ids: [], added_action_ids: [],
          removed_action_ids: [] })
      end
    end
    scenario = Scenario.new
    task = scenario.task(state: "backlog")
    after = scenario.workspace.reload.last_seq
    T::Table.with_entries("complete_contract" => only_contract) do
      T.apply(T::Request.new(command: "complete_contract", workspace_id: scenario.workspace_id, caller_kind: "owner",
        caller_id: scenario.owner.id, key: "audit-short", request_hash: "a" * 64, params: { "id" => task.id }))
    end
    found = Leverage::LogAudit.call(scenario.workspace_id, after_seq: after)
    assert(found.any? { |line| line.include?("audit-short") && line.include?("complete_contract") }, found.inspect)
  end

  test "a refused command that wrote an event of its own is found" do
    runner = run_trace("10-leases-no-rules")
    key = key_of(runner, "$key:t1_pass_copy_late")
    task = Task.find_by!(workspace_id: runner.workspace_id)
    seat = Seat.find_by!(workspace_id: runner.workspace_id, role: "builder")
    append_under(runner, key, "task.briefing_acknowledged", task: task, caller: seat.id)
    found = audit(runner)
    assert(found.any? { |line| line.include?(key) && line.include?("refused") }, found.inspect)
  end

  test "an event with no command that no timer writes is found" do
    runner = run_trace("09-core-loop-no-rules")
    task = Task.find_by!(workspace_id: runner.workspace_id)
    append_under(runner, nil, "task.briefing_acknowledged", task: task)
    found = audit(runner)
    assert(found.any? { |line| line.include?("no command") }, found.inspect)
  end

  test "steps that do not touch end to end are found" do
    runner = run_trace("09-core-loop-no-rules")
    TaskStep.where(workspace_id: runner.workspace_id).where("closed_at > opened_at").order(:opened_at).second.delete
    found = audit(runner)
    assert(found.any? { |line| line.include?("steps") }, found.inspect)
  end

  test "a task whose effective times go backwards is found" do
    runner = run_trace("09-core-loop-no-rules")
    task = Task.find_by!(workspace_id: runner.workspace_id)
    first = Event.where(task_id: task.id).order(:seq).first
    ActiveRecord::Base.transaction(requires_new: true) do
      runner.scenario.context.emit("criterion.reopened", task: task,
        subject: Criterion.where(task_id: task.id, kind: "build").first, actor_kind: "app", actor_id: nil,
        command_id: nil, effective_at: first.effective_at - 1)
    end
    found = audit(runner)
    assert(found.any? { |line| line.include?("backwards") }, found.inspect)
  end
end
