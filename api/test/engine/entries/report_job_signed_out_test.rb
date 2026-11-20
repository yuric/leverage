require "test_helper"
require_relative "jobs_support"

# report_job_signed_out (PRD L684, L688, L698, L872; milestone 4 plan
# RD-40): the helper reports that a job's run found its login signed out.
# Carried out as report_job_limit, but the login becomes signed out and
# credential.signed_out is written, naming the seat and the job. Its rows
# have no side event, so no "Account signed out" item opens beside another
# task's hold here.
class ReportJobSignedOutTest < ActiveSupport::TestCase
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

  def report(credential, key: new_key)
    helper_command("report_job_signed_out", signed_out_params(credential, @orchestrator, job_id: @job.id), key: key)
  end

  test "with a candidate below, the job's run goes on there" do
    written = ensured = nil
    ended = runs_ended { ensured = runs_ensured { written = events_written { assert_completed(report(@codex_o)) } } }

    signed_out, switched = written
    assert_equal %w[credential.signed_out credential.switched], types(written)
    assert_equal [ @codex_o.id, @task.id, { "seat_id" => @orchestrator.id, "review_id" => nil, "job_id" => @job.id } ],
      [ signed_out.subject_id, signed_out.task_id, signed_out.payload ]
    assert_equal [ @grok_o.id, signed_out.id, @job.id ], [ switched.subject_id, switched.cause_id, switched.payload["job_id"] ]
    assert_equal "signed_out", @codex_o.reload.state
    assert_equal [ "claimed", @grok_o.id ], @job.reload.attributes.values_at("state", "credential_id")
    assert_equal [ [ @orchestrator.id, @grok_o.id, nil ] ], ensured
    assert_equal [ [ @orchestrator.id, "signed_out" ] ], ended
  end

  test "with no candidate, only the sign-out is written, and no item opens beside another task's hold" do
    scenario.limit_credential(@grok_o, reset_at: from_now(900))
    builder = scenario.seat(role: "builder", credential: @codex_o)
    held = scenario.task(state: "working", builder: builder)
    scenario.hold(held, reason: "credential_limit", credential: @codex_o, item: false)

    written = events_written { assert_completed(report(@codex_o)) }

    assert_equal %w[credential.signed_out], types(written)
    assert_equal 0, InboxItem.where(about_id: held.id, state: "open").count
  end

  test "the refusals are report_job_limit's" do
    @job.update!(state: "withdrawn")

    written = events_written { assert_refused("invalid_state", report(@codex_o)) }

    assert_empty written
    assert_equal "active", @codex_o.reload.state
  end
end
