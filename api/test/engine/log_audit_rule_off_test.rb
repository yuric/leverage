require "test_helper"
require_relative "entries/jobs_support"

# RT-4's gate line and a rule turned off while its command waits (PRD L380:
# "A rule turned off or removed during a check withdraws that check, and
# the transition completes if nothing else blocks it"; L976: "the tasks
# proceed at once"). A frozen gate whose rule is off or removed when the
# last result comes no longer blocks, even when its check had already
# failed while another check still ran (Rules::Reentry step 2): the engine
# completes the move. The audit holds the gate to the frozen versions
# whose rules are still on at that point of the log, as its own line says
# ("an enabled blocking gate in its frozen set"). StepPartitionTest's walk
# 139 (seed 805) took this path under the whole suite and failed the gate
# line.
class LogAuditRuleOffTest < ActiveSupport::TestCase
  include JobsSupport

  FAILED = { "result" => "failed", "reason" => "The details do not say which prices change." }.freeze
  PASSED = { "result" => "passed", "reason" => "The details name the page and the prices." }.freeze

  setup do
    use_scenario
    @orchestrator = scenario.orchestrator(credential: scenario.credential(provider: "codex", model: nil), model: "codex-model-1")
    @rules = [ model_rule(name: "Made-up first rule"), model_rule(name: "Made-up second rule") ]
    @task = scenario.task(state: "backlog", criteria: [])
    @start = scenario.workspace.reload.last_seq
    assert_equal :pending, owner_command("complete_contract", contract_body.merge("id" => @task.id)).outcome
  end

  # Claims the next job and answers it; returns the rule its check is of.
  def answer_next(result)
    claimed = assert_completed(claim_job(@orchestrator))
    job = Job.find(claimed.result.fetch("job_id"))
    assert_completed(submit_result(@orchestrator, job, result))
    check = RuleCheck.find(RuleCheckAttempt.find_by!(job_id: job.id).rule_check_id)
    Rule.find(check.rule_id)
  end

  { "disable_rule" => "turned off", "remove_rule" => "removed" }.each do |command, done|
    test "a move past a frozen gate whose check failed and whose rule was then #{done} passes" do
      failed_rule = answer_next(FAILED)
      assert_equal "backlog", @task.reload.state, "the other check still runs"
      assert_completed(owner_command(command, { "id" => failed_rule.id }))
      answer_next(PASSED)

      assert_equal "ready", @task.reload.state, "the engine lets the move through (L380, L976)"
      assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: @start)
    end
  end

  test "a move past a frozen gate whose check failed, its rule still on, is refused, and the audit finds nothing" do
    answer_next(FAILED)
    answer_next(PASSED)

    assert_equal "backlog", @task.reload.state
    assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: @start)
  end
end
