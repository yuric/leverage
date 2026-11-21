require "test_helper"
require_relative "jobs_support"

# claim_job (PRD L540, L545, L872; milestone 4 plan RD-34 to RD-36, RD-40,
# IF-13; traces 16 and 19): an orchestrator or a planner claims the oldest
# job its role takes, or gets the one it holds again. job.claimed records
# the credential and the model; a rule check's attempt starts
# (RuleChecks.start, WP4's); the answer is ClaimJobResult with the job's
# input (JobInputs) and run_due_at (Timers.job_due_at(job, :run)).
class ClaimJobTest < ActiveSupport::TestCase
  include JobsSupport
  include OpenapiAssertions

  setup do
    use_scenario
    @codex = scenario.credential(provider: "codex", model: nil)
    @claude = scenario.credential(provider: "claude", model: nil)
    @orchestrator = scenario.orchestrator(credential: @codex, model: "codex-model-1")
    @planner = scenario.planner(credential: @claude, model: "claude-model-1")
  end

  test "trace 16 command 3: the orchestrator claims the check's job; the attempt starts; run_due_at is the run timeout" do
    _task, _pending, check = waiting_contract(model_rule)
    job = job_of(check)
    key = new_key
    written = outcome = due = nil
    starts = starting_attempts do
      due = spy_on(Leverage::Timers, :job_due_at) do
        written = events_written { outcome = assert_completed(claim_job(@orchestrator, key: key)) }
      end
    end

    claimed = written.sole
    assert_equal [ "job.claimed", "job", job.id, check.task_id, "seat", @orchestrator.id, key ],
      [ claimed.type, claimed.subject_kind, claimed.subject_id, claimed.task_id, claimed.actor_kind, claimed.actor_id,
        claimed.command_id ]
    assert_equal({ "credential_id" => @codex.id, "model" => "codex-model-1" }, claimed.payload)
    assert_equal [ [ check.id, job.id, @orchestrator.id ] ],
      starts.map { |call| [ call.arguments[1].id, call.keywords[:job].id, call.keywords[:seat].id ] }
    assert_includes due.map { |call| [ call.arguments.first.id, call.arguments.last ] }, [ job.id, :run ]

    result = outcome.result
    assert_matches_component("ClaimJobResult", result)
    assert_equal [ job.id, "rule_check", @codex.id, "codex-model-1" ], result.values_at("job_id", "kind", "credential_id", "model")
    assert_equal Leverage::JobInputs.for(job.reload), result.fetch("input")
    assert_equal (claimed.at + 300).utc.iso8601(6), result.fetch("run_due_at")
  end

  test "trace 16 command 10: the planner claims the draft; no attempt starts; run_due_at is the claim plus the run timeout" do
    task = scenario.task(state: "backlog", criteria: [])
    job = scenario.job(kind: "contract_draft", task: task, input: { "task_id" => task.id, "project_id" => nil,
      "brief_version" => 0 })
    written = outcome = nil
    starts = spy_on(Leverage::RuleChecks, :start) do
      written = events_written { outcome = assert_completed(claim_job(@planner)) }
    end

    assert_empty starts
    assert_equal [ [ "job.claimed", job.id ] ], written.map { |event| [ event.type, event.subject_id ] }
    assert_matches_component("ClaimJobResult", outcome.result)
    assert_equal [ job.id, "contract_draft", @claude.id, "claude-model-1" ],
      outcome.result.values_at("job_id", "kind", "credential_id", "model")
    assert_equal (written.sole.at + 300).utc.iso8601(6), outcome.result.fetch("run_due_at")
  end

  test "a seat that holds a job gets that job again and nothing is written (RD-40)" do
    _task, _pending, check = waiting_contract(model_rule)
    first = nil
    starting_attempts { first = assert_completed(claim_job(@orchestrator)) }
    waiting_contract(model_rule)

    again = nil
    written = events_written { starting_attempts { again = assert_completed(claim_job(@orchestrator)) } }

    assert_empty written
    assert_equal first.result, again.result
    assert_equal job_of(check).id, again.result.fetch("job_id")
  end

  test "the oldest job is claimed first" do
    _t1, _p1, older = waiting_contract(model_rule)
    _t2, _p2, newer = waiting_contract(model_rule)
    Job.where(id: job_of(newer).id).update_all(queued_at: job_of(older).queued_at + 1)

    outcome = nil
    starting_attempts { outcome = assert_completed(claim_job(@orchestrator)) }

    assert_equal job_of(older).id, outcome.result.fetch("job_id")
  end

  test "nothing to claim, or a seat of another role, is not_eligible and writes nothing" do
    waiting_contract(model_rule)
    builder = scenario.seat(role: "builder", credential: @codex)

    written = events_written do
      assert_refused("not_eligible", claim_job(@planner))
      assert_refused("not_eligible", claim_job(builder))
    end

    assert_empty written
    assert_equal "queued", Job.where(workspace_id: scenario.workspace_id).sole.state
  end

  test "a seat the app runs whose logins are all limited claims nothing (RD-40: it stops claiming jobs)" do
    waiting_contract(model_rule)
    scenario.limit_credential(@codex, reset_at: from_now(900))
    scenario.limit_credential(@claude, reset_at: from_now(900))

    assert_refused("not_eligible", claim_job(@orchestrator))
  end

  test "claiming an approval job starts its check attempt" do
    task = scenario.task(state: "working", actions: [ { kind: "publish", description: "Publish the sample." } ])
    action = Action.find_by!(task_id: task.id)
    check = scenario.rule_check(task, rule: model_rule(hook: "action.requested"), subject: action, attempts: 0)
    request = Leverage::Transitions::Request.new(command: "request_action", workspace_id: scenario.workspace_id,
      caller_kind: nil, caller_id: nil, key: nil, request_hash: nil, params: { "action_id" => action.id })
    attempt = Leverage::RuleChecks.queue_attempt(scenario.context(request: request), check, kind: "approval")
    job = Job.find(attempt.job_id)
    outcome = nil
    calls = answering(Leverage::JobInputs::Approval, :call, ->(*) { {} }) do
      outcome = assert_completed(claim_job(@orchestrator))
    end

    assert_equal [ job.id, "approval" ], outcome.result.values_at("job_id", "kind")
    assert_equal job.id, calls.sole.arguments.first.id
    assert_equal @orchestrator.id, RuleCheckAttempt.find_by!(job_id: job.id).checker_seat_id
    assert Event.exists?(workspace_id: scenario.workspace_id, type: "check.started", subject_id: check.id)
    assert_equal (job.reload.claimed_at + 300).utc.iso8601(6), outcome.result.fetch("run_due_at")
  end

  test "a seat that changes jobs role cannot reclaim question material or take a second job" do
    seat = own_seat(role: "orchestrator")
    task = scenario.task(state: "working")
    question = scenario.question(task)
    question_job = scenario.job(kind: "question", task: task, target: question)
    assert_equal question_job.id, assert_completed(claim_job(seat)).result.fetch("job_id")
    draft_job = scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"))

    assert_completed(owner_command("change_seat", { "id" => seat.id, "role" => "planner" }))

    assert_nil Leverage::Jobs.next_for(seat.reload, at: scenario.database_now)
    assert_refused("not_eligible", claim_job(seat))
    assert_equal [ "claimed", "queued" ], [ question_job.reload.state, draft_job.reload.state ]
  end

  test "a seat that built a task cannot claim its question job after becoming an orchestrator" do
    former_builder = own_seat
    task = scenario.task(state: "working", builder: former_builder)
    assert_completed(seat_command(former_builder, "release", { "id" => task.id, "reason" => "unable_to_continue" }))
    former_builder.update!(role: "orchestrator")
    question = scenario.question(task)
    job = scenario.job(kind: "question", task: task, target: question)

    assert_refused("not_eligible", claim_job(former_builder))
    assert_equal "queued", job.reload.state
    assert_equal job.id, assert_completed(claim_job(@orchestrator)).result.fetch("job_id")
  end
end
