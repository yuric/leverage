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

  def run_trace(name)
    TraceRunner.new(name).run.tap { |runner| assert_empty runner.failures, runner.failures.join("\n") }
  end

  def audit(runner) = Leverage::LogAudit.call(runner.workspace_id, after_seq: runner.setup_seq)

  def key_of(runner, symbol) = Leverage::Contract::TraceBinder.new(start: Time.current).id(symbol)

  # Appends one event as if the command with this key wrote it later.
  def append_under(runner, key, type, task:, payload: {}, caller: nil)
    request = T::Request.new(command: "audit_test", workspace_id: runner.workspace_id, caller_kind: caller && "seat",
      caller_id: caller, key: key, request_hash: nil, params: {})
    ActiveRecord::Base.transaction(requires_new: true) do
      runner.scenario.context(request: request).emit(type, task: task, payload: payload)
    end
  end

  %w[09-core-loop-no-rules 10-leases-no-rules].each do |name|
    test "the log of trace #{name} passes" do
      assert_empty audit(run_trace(name))
    end
  end

  test "the log of a walk, every event of it written by a command, passes from its first event" do
    walk = Walk.new(seed: 21).run
    assert_empty Leverage::LogAudit.call(walk.workspace_id), walk.to_s
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
        ctx.emit("task.contract_changed", task: @task, payload: { contract_version: 1, added_criterion_ids: [],
          reset_criterion_ids: [], removed_criterion_ids: [], added_action_ids: [], removed_action_ids: [] })
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
