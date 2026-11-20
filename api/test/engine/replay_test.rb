require "test_helper"
require_relative "../support/trace_runner"
require_relative "../support/walk"

# Replay (PRD test 1, "What the replay test rebuilds"; DB-43, DB-44):
# rebuilding from the log reproduces exactly the replay columns: tasks'
# state, round, holder, builder, minimum strength rank and contract
# version; criteria's state; reviews' verdict; actions' state; the open
# holds with their reasons; rule checks' result and override; rules'
# enabled and current version; projects' paused and spent; and every
# task_steps row. Leverage::Replay.diff lists every column where the
# tables and the log disagree, so a change that went around the log is
# found.
class ReplayTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  def run_trace(name)
    TraceRunner.new(name).run.tap { |runner| assert_empty runner.failures, runner.failures.join("\n") }
  end

  def log_diff(runner) = Leverage::Replay.diff(runner.workspace_id)

  # Milestone 3 adds traces 11 to 15 (its plan HT-1): handoffs, credential
  # holds, their timer, Sign in again, and the owner's controls.
  %w[
    09-core-loop-no-rules 10-leases-no-rules 11-limit-handoff-no-rules 12-signed-out-hold-verify-no-rules
    13-limit-next-signed-out-no-rules 14-handoff-edges-no-rules 15-owner-controls-no-rules
  ].each do |name|
    test "the log of trace #{name} rebuilds every replay column" do
      assert_empty log_diff(run_trace(name))
    end
  end

  # Milestone 4 (its plan RT-1, test 1): the rule checks' result and
  # override, the rules' switch and current version, a provisional claim's
  # holder (DB-43), and the steps check and draft, in the traces that write
  # them, and in the milestone 1 traces that run whole with rules.
  %w[
    01-happy-path 02-failed-review-rework 05-limit-handoff 06-signed-out-hold-verify
    07-pending-gate-check-error-override 08-lease-expiry-and-cancel 16-model-gate-and-draft
    17-submit-rule-rerun-and-override 18-claim-gate-done-gate-and-ends 19-provider-rule-offline-and-jobs
  ].each do |name|
    test "the log of trace #{name}, with its rules and checks, rebuilds every replay column" do
      assert_empty log_diff(run_trace(name))
    end
  end

  # RD-45, DB-49: the check held at the re-run limit has no attempt, no
  # job and no check event; its rerun_limit hold's hold.opened names it, so
  # the log makes its row while the owner has not answered.
  test "the log of trace 17 at the re-run limit, before the owner answers, rebuilds the held check's row" do
    runner = TraceRunner.new("17-submit-rule-rerun-and-override").run(28)
    assert_empty runner.failures, runner.failures.join("\n")
    held = Hold.find_by!(workspace_id: runner.workspace_id, reason: "rerun_limit", closed_at: nil)
    assert_equal({ "result" => nil, "overridden_by_user_id" => nil, "overridden_at" => nil },
      Leverage::Replay.project(runner.workspace_id).fetch(:rule_checks).fetch(held.rule_check_id))
    assert_empty log_diff(runner)
  end

  test "a rule's switch and current version changed without an event are found" do
    runner = run_trace("17-submit-rule-rerun-and-override")
    rules = Leverage::Replay.project(runner.workspace_id).fetch(:rules)
    assert_equal Rule.where(workspace_id: runner.workspace_id).pluck(:id).sort, rules.keys.sort
    custom = Rule.where(workspace_id: runner.workspace_id, removed_at: nil).where("key LIKE 'custom_%'").order(:created_at).first
    assert_operator rules.fetch(custom.id).fetch("current_version"), :>, 1, "trace 17 saves its rule as a new version"
    custom.update_columns(enabled: !custom.enabled, current_version: custom.current_version - 1)
    found = log_diff(runner)
    assert(found.any? { |line| line.include?("rules #{custom.id} enabled") }, found.inspect)
    assert(found.any? { |line| line.include?("rules #{custom.id} current_version") }, found.inspect)
  end

  test "a rule check's result and override changed without an event are found" do
    runner = run_trace("07-pending-gate-check-error-override")
    checks = Leverage::Replay.project(runner.workspace_id).fetch(:rule_checks)
    overridden = RuleCheck.where(workspace_id: runner.workspace_id).where.not(overridden_at: nil).sole
    assert_equal [ "error", overridden.overridden_by_user_id, overridden.overridden_at ],
      checks.fetch(overridden.id).values_at("result", "overridden_by_user_id", "overridden_at")
    passed = RuleCheck.where(workspace_id: runner.workspace_id, result: "passed").sole
    passed.update_columns(result: "failed")
    overridden.update_columns(overridden_at: nil, overridden_by_user_id: nil)
    found = log_diff(runner)
    assert(found.any? { |line| line.include?("rule_checks #{passed.id} result") }, found.inspect)
    assert(found.any? { |line| line.include?("rule_checks #{overridden.id} overridden_at") }, found.inspect)
    assert(found.any? { |line| line.include?("rule_checks #{overridden.id} overridden_by_user_id") }, found.inspect)
  end

  # DB-43: the provisional holder is set by the claim check's check.queued
  # (claimant_seat_id) and cleared by its failed, errored or withdrawn
  # check.finished, by a hold.opened on the task and by task.released.
  test "a provisional claim's holder is rebuilt from its check, and cleared when the check fails" do
    scenario = Scenario.new
    rule = scenario.rule(hook: "task.before_claim")
    task = scenario.task(state: "ready")
    builder = scenario.seat
    seat_call = lambda do |seat, command, params|
      T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat",
        caller_id: seat.id, key: "k-#{SecureRandom.hex(6)}", request_hash: "c" * 64, params: params))
    end
    assert_equal :pending, seat_call.call(builder, "claim", {}).outcome
    holder = -> { Leverage::Replay.project(scenario.workspace_id).fetch(:tasks).fetch(task.id).fetch("holder_seat_id") }
    assert_equal [ builder.id, builder.id ], [ holder.call, task.reload.holder_seat_id ]
    assert_empty Leverage::Replay.diff(scenario.workspace_id)

    orchestrator = scenario.orchestrator
    assert seat_call.call(orchestrator, "claim_job", {}).completed?
    job = Job.find_by!(workspace_id: scenario.workspace_id, state: "claimed")
    assert seat_call.call(orchestrator, "submit_job_result", "id" => job.id,
      "result" => { "result" => "failed", "reason" => "A made-up reason." }, "tokens" => 1, "spend" => 0).completed?
    assert_equal "failed", RuleCheck.find_by!(workspace_id: scenario.workspace_id, rule_id: rule.id).result
    assert_equal [ nil, nil ], [ holder.call, task.reload.holder_seat_id ]
    assert_empty Leverage::Replay.diff(scenario.workspace_id)
  end

  # The open set of holds with its reasons, mid-trace: trace 11 after its
  # second limit (a credential_limit hold waits for the reset), trace 12
  # after its sign-out (credential_signed_out), trace 15 while an agent is
  # paused (seat_paused).
  { "11-limit-handoff-no-rules" => [ 9, "credential_limit" ], "12-signed-out-hold-verify-no-rules" => [ 8, "credential_signed_out" ],
    "15-owner-controls-no-rules" => [ 10, "seat_paused" ] }.each do |name, (commands, reason)|
    test "the open #{reason} hold of trace #{name} is rebuilt from the log, and so is every step" do
      runner = TraceRunner.new(name).run(commands)
      assert_empty runner.failures, runner.failures.join("\n")
      holds = Leverage::Replay.project(runner.workspace_id).fetch(:holds)
      assert_equal [ reason ], holds.values.map { |hold| hold.fetch("reason") }
      assert_equal Hold.where(workspace_id: runner.workspace_id, closed_at: nil).pluck(:id), holds.keys
      assert_empty log_diff(runner)
    end
  end

  test "the log of a random walk rebuilds every replay column" do
    [ 11, 12, 13 ].each do |seed|
      walk = Walk.new(seed: seed).run
      assert_empty Leverage::Replay.diff(walk.workspace_id), walk.to_s
    end
  end

  test "the projection follows the holder and builder rules of DB-43 and L781" do
    runner = run_trace("10-leases-no-rules")
    projection = Leverage::Replay.project(runner.workspace_id)
    task = Task.find_by!(workspace_id: runner.workspace_id)
    row = projection.fetch(:tasks).fetch(task.id)
    assert_equal({ "state" => "cancelled", "round" => 4, "holder_seat_id" => nil, "builder_seat_id" => nil,
                   "minimum_strength_rank" => nil, "contract_version" => 1 }, row)
    assert_empty projection.fetch(:holds), "Cancel closed the second rounds_exceeded hold"
    assert_equal [ "failed" ] * 4, projection.fetch(:reviews).values.map { |review| review.fetch("verdict") }
  end

  test "a task column changed without an event is found" do
    runner = run_trace("09-core-loop-no-rules")
    task = Task.find_by!(workspace_id: runner.workspace_id)
    task.update_columns(round: 7, builder_seat_id: nil)
    found = log_diff(runner)
    assert(found.any? { |line| line.include?("tasks #{task.id} round") }, found.inspect)
    assert(found.any? { |line| line.include?("tasks #{task.id} builder_seat_id") }, found.inspect)
  end

  test "a criterion's state and a review's verdict changed without an event are found" do
    runner = run_trace("09-core-loop-no-rules")
    criterion = Criterion.where(workspace_id: runner.workspace_id, kind: "build").order(:position).first
    criterion.update_columns(state: "open")
    review = Review.where(workspace_id: runner.workspace_id).order(:round).first
    review.update_columns(verdict: "passed")
    found = log_diff(runner)
    assert(found.any? { |line| line.include?("criteria #{criterion.id} state") }, found.inspect)
    assert(found.any? { |line| line.include?("reviews #{review.id} verdict") }, found.inspect)
  end

  test "a hold closed or opened without an event is found" do
    runner = run_trace("10-leases-no-rules")
    hold = Hold.where(workspace_id: runner.workspace_id).order(:opened_at).last
    hold.update_columns(closed_at: nil)
    assert(log_diff(runner).any? { |line| line.include?("holds #{hold.id}") }, log_diff(runner).inspect)
  end

  test "a step row the log does not give is found" do
    runner = run_trace("09-core-loop-no-rules")
    step = TaskStep.where(workspace_id: runner.workspace_id).order(:opened_at).second
    step.update_columns(kind: "build", step_class: "working")
    assert(log_diff(runner).any? { |line| line.start_with?("task_steps") }, log_diff(runner).inspect)
  end

  test "a missing step row is found" do
    runner = run_trace("09-core-loop-no-rules")
    TaskStep.where(workspace_id: runner.workspace_id).order(:opened_at).last.delete
    assert(log_diff(runner).any? { |line| line.start_with?("task_steps") }, log_diff(runner).inspect)
  end

  test "a project's paused and spent are rebuilt from its events" do
    scenario = Scenario.new
    project = scenario.project
    task = scenario.task(state: "backlog")
    scenario.append("project.paused", project_id: project.id, actor_kind: "owner", actor_id: scenario.owner.id)
    scenario.append("cost.reported", task: task, project_id: project.id, payload: { tokens: 5, spend: 0.25 })
    project.update_columns(paused: true, spent: 0.25)
    assert_empty Leverage::Replay.diff(scenario.workspace_id)

    project.update_columns(spent: 1)
    assert(Leverage::Replay.diff(scenario.workspace_id).any? { |line| line.include?("projects #{project.id} spent") })
  end

  test "the replay changes nothing: the tables are as they were after a diff" do
    runner = run_trace("10-leases-no-rules")
    before = TaskStep.where(workspace_id: runner.workspace_id).order(:id).pluck(:id, :kind, :closed_at)
    log_diff(runner)
    assert_equal before, TaskStep.where(workspace_id: runner.workspace_id).order(:id).pluck(:id, :kind, :closed_at)
  end

  # Complete contract is the one command of this milestone that sets the
  # rank; its task.contract_changed carries it (null for none).
  def complete_contract(scenario, task, minimum_strength_rank)
    params = { "id" => task.id, "title" => task.title, "goal" => task.goal, "details" => nil,
               "criteria" => [ { "text" => "Made-up criterion.", "kind" => "build" },
                               { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
               "actions" => [], "minimum_strength_rank" => minimum_strength_rank, "budget_cap" => nil,
               "work_reference" => nil }
    T.apply(T::Request.new(command: "complete_contract", workspace_id: scenario.workspace_id, caller_kind: "owner",
      caller_id: scenario.owner.id, key: "k-#{SecureRandom.hex(6)}", request_hash: Digest::SHA256.hexdigest(params.to_json),
      params: params)).tap { |outcome| assert outcome.completed?, outcome.refusal&.code }
  end

  test "a minimum strength rank set by Complete contract is rebuilt" do
    scenario = Scenario.new
    ranked = scenario.task(state: "backlog", work_reference: nil)
    unranked = scenario.task(state: "backlog", work_reference: nil)
    complete_contract(scenario, ranked, 2)
    complete_contract(scenario, unranked, nil)

    assert_equal [ 2, nil ], [ ranked.reload.minimum_strength_rank, unranked.reload.minimum_strength_rank ]
    tasks = Leverage::Replay.project(scenario.workspace_id).fetch(:tasks)
    assert_equal 2, tasks.fetch(ranked.id).fetch("minimum_strength_rank")
    assert_nil tasks.fetch(unranked.id).fetch("minimum_strength_rank")
    assert_empty Leverage::Replay.diff(scenario.workspace_id)

    ranked.update_columns(minimum_strength_rank: 3)
    found = Leverage::Replay.diff(scenario.workspace_id)
    assert(found.any? { |line| line.include?("tasks #{ranked.id} minimum_strength_rank") }, found.inspect)
  end

  # Found by the walks of milestone 3 (seed 36 of SEED=1): an edit removes
  # a builder criterion the tracker counted when another passed, so the
  # criteria a step decision read must be those of the log as of the event
  # (task.contract_changed's added and removed ids), not the rows as they
  # are at the replay.
  test "an edit that removes a criterion does not change the steps the replay rebuilds before it" do
    scenario = Scenario.new
    builder = scenario.seat(role: "builder")
    task = scenario.task(state: "working", builder: builder, criteria: %w[build build review])
    first, = Criterion.where(task_id: task.id, kind: "build").order(:position).to_a
    seat_call = lambda do |command, params|
      T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat",
        caller_id: builder.id, key: "k-#{SecureRandom.hex(6)}", request_hash: "a" * 64, params: params))
    end
    assert seat_call.call("acknowledge_briefing", "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task.reload, builder)).completed?
    assert seat_call.call("pass_criterion", "id" => task.id, "cid" => first.id,
      "evidence" => { "kind" => "link", "value" => "https://example.test/work/1" }).completed?
    edit = { "id" => task.id, "title" => task.title, "goal" => task.goal, "details" => nil,
             "criteria" => [ { "text" => first.text, "kind" => "build" }, { "text" => "A reviewer agrees.", "kind" => "review" } ],
             "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }
    owner_call = lambda do |command, params|
      T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "owner",
        caller_id: scenario.owner.id, key: "k-#{SecureRandom.hex(6)}", request_hash: "b" * 64, params: params))
    end
    assert owner_call.call("edit_contract", edit).completed?
    assert_empty log_diff(Struct.new(:workspace_id).new(scenario.workspace_id))

    # Then the other way: an edit that changes the first criterion (reset)
    # and leaves the second removed; its next pass is the last builder
    # criterion's, and finish opens, which the removed one must not stop.
    changed = edit.merge("criteria" => [ { "text" => "#{first.text} Changed.", "kind" => "build" },
                                         { "text" => "A reviewer agrees.", "kind" => "review" } ])
    assert owner_call.call("edit_contract", changed).completed?
    assert owner_call.call("complete_contract", changed).completed?
    assert seat_call.call("claim", {}).completed?
    assert seat_call.call("acknowledge_briefing", "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task.reload, builder)).completed?
    assert seat_call.call("pass_criterion", "id" => task.id, "cid" => first.id,
      "evidence" => { "kind" => "link", "value" => "https://example.test/work/2" }).completed?
    assert_equal "finish", TaskStep.where(task_id: task.id, closed_at: nil).sole.kind
    assert_empty log_diff(Struct.new(:workspace_id).new(scenario.workspace_id))
  end
end
