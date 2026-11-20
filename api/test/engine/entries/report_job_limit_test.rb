require "test_helper"
require_relative "jobs_support"

# report_job_limit (PRD L399, L401, L679, L688, L698, L872; milestone 4
# plan RD-40; trace 19 commands 26 and 27): the helper reports that a job's
# run met a provider limit. The credential is marked and
# credential.limit_reached is written on the job's task, naming the job
# (Handoff.interrupt). With a candidate below, credential.switched names the
# job, the job's run goes on there (SeatRuns.ensure_run_on) and the job
# stays claimed; with none, nothing more: the seat stops claiming jobs and
# the job runs into its run timeout. No task state is read and no task hold
# opens.
class ReportJobLimitTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @codex_o = scenario.credential(provider: "codex", model: nil)
    @grok_o = scenario.credential(provider: "grok", model: "grok-model-1")
    @orchestrator = scenario.orchestrator(credential: @codex_o, model: "codex-model-1")
    @task, _pending, @check = waiting_contract(model_rule)
    starting_attempts { assert_completed(claim_job(@orchestrator)) }
    @job = job_of(@check)
  end

  def report(credential, key: new_key, **options)
    helper_command("report_job_limit", limit_params(credential, @orchestrator, job_id: @job.id, **options), key: key)
  end

  test "trace 19 command 26: with a candidate below, the job's run goes on there, and the job stays claimed" do
    reset = from_now(470)
    key = new_key
    written = ensured = nil
    ended = runs_ended do
      ensured = runs_ensured { written = events_written { assert_completed(report(@codex_o, reset_at: reset, key: key)) } }
    end

    limit, switched = written
    assert_equal %w[credential.limit_reached credential.switched], types(written)
    assert_equal [ "credential", @codex_o.id, @task.id, "app", scenario.helper.id, key, nil ],
      [ limit.subject_kind, limit.subject_id, limit.task_id, limit.actor_kind, limit.actor_id, limit.command_id, limit.cause_id ]
    assert_equal({ "seat_id" => @orchestrator.id, "review_id" => nil, "job_id" => @job.id, "window" => "five_hour",
                   "reset_at" => reset.utc.iso8601(6) }, limit.payload)
    assert_equal [ "credential", @grok_o.id, @task.id, limit.id, "app", scenario.helper.id ],
      [ switched.subject_kind, switched.subject_id, switched.task_id, switched.cause_id, switched.actor_kind, switched.actor_id ]
    assert_equal({ "from_credential_id" => @codex_o.id, "model" => "grok-model-1", "seat_id" => @orchestrator.id,
                   "review_id" => nil, "job_id" => @job.id }, switched.payload)
    assert_equal [ "claimed", @orchestrator.id, @grok_o.id ],
      @job.reload.attributes.values_at("state", "claimed_by_seat_id", "credential_id")
    assert_equal [ [ @orchestrator.id, @grok_o.id, nil ] ], ensured
    assert_equal [ [ @orchestrator.id, "limit" ] ], ended
    assert @codex_o.reload.limited?(scenario.database_now)
  end

  test "trace 19 command 27: with no candidate below, only the limit is written and the job runs into its timeout" do
    assert_completed(report(@codex_o, reset_at: from_now(470)))
    scenario.run(@orchestrator, on: @grok_o)

    written = events_written { assert_completed(report(@grok_o, reset_at: from_now(460))) }

    assert_equal %w[credential.limit_reached], types(written)
    assert_equal @job.id, written.sole.payload["job_id"]
    assert_equal [ "claimed", @grok_o.id ], @job.reload.attributes.values_at("state", "credential_id")
    assert_nil Hold.find_by(task_id: @task.id)
    assert_nil Leverage::Jobs.next_for(@orchestrator.reload), "the seat stops claiming jobs"
  end

  test "the seat's run goes back to its own login when only that one is available (rule 4)" do
    scenario.limit_credential(@grok_o, reset_at: from_now(900))
    stray = scenario.credential(provider: "claude")
    scenario.run(@orchestrator, on: stray)
    @job.update!(credential_id: stray.id)

    written = events_written { assert_completed(report(stray, reset_at: from_now(400))) }

    assert_equal [ "credential.switched", @codex_o.id ], [ written.last.type, written.last.subject_id ]
  end

  test "a job the seat does not hold is not_holder; a job no longer claimed or a stale credential is invalid_state" do
    other = scenario.orchestrator(credential: @codex_o)
    assert_refused("not_holder",
      helper_command("report_job_limit", limit_params(@codex_o, other, job_id: @job.id, reset_at: from_now(400))))
    assert_refused("invalid_state", report(@grok_o, reset_at: from_now(400)))

    @job.update!(state: "timed_out")
    written = events_written { assert_refused("invalid_state", report(@codex_o, reset_at: from_now(400))) }

    assert_empty written
    assert_nil @codex_o.reload.limited_since
  end

  test "a job, credential or seat outside the workspace is 404; a report that also names a task is 422" do
    foreign = Scenario.new
    foreign_job = foreign.job(kind: "contract_draft", task: foreign.task(state: "backlog"))
    assert_raises(T::NotFound) do
      helper_command("report_job_limit", limit_params(@codex_o, @orchestrator, job_id: foreign_job.id))
    end
    assert_raises(T::NotFound) do
      helper_command("report_job_limit", limit_params(foreign.credential, @orchestrator, job_id: @job.id))
    end
    assert_raises(T::Invalid) { report(@codex_o, task: @task) }
    assert_raises(T::Invalid) do
      helper_command("report_job_limit", limit_params(@codex_o, @orchestrator, job_id: @job.id).merge("credential_id" => @grok_o.id))
    end
    assert_nil @codex_o.reload.limited_since
  end
end
