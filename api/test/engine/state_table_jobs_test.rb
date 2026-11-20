require "test_helper"
require_relative "entries/jobs_support"

# Test 3 (PRD L836; milestone 4 plan RT-5) for the rows of this package:
# draft_contract (every task state), the jobs group (claim_job,
# submit_job_result) and the four rows of the two job reports
# (report_job_limit, report_job_signed_out), from StateTableCases. A row
# writes its own events in order; the side events it may write beside them
# (check.started, check.finished) are the seams' of WP4, so the case
# asserts that the row's own events are what is written besides them.
class StateTableJobsTest < ActiveSupport::TestCase
  include JobsSupport

  COMMANDS = %w[draft_contract claim_job submit_job_result report_job_limit report_job_signed_out].freeze

  # Side events a jobs row may write, which seams of other packages write.
  SIDE = %w[check.started check.finished].freeze

  setup do
    use_scenario
    @codex = scenario.credential(provider: "codex", model: nil)
    @grok = scenario.credential(provider: "grok", model: "grok-model-1")
    @orchestrator = scenario.orchestrator(credential: @codex, model: "codex-model-1")
  end

  StateTableCases.define(self, COMMANDS) do |kase|
    if kase.invalid_state? then assert_invalid_state(kase)
    else assert_row(kase)
    end
  end

  private

  def assert_invalid_state(kase)
    task = task_in(kase.from)
    written = events_written { assert_refused(kase.refusal, owner_command(kase.command, { "id" => task.id })) }

    assert_empty written, kase.name
  end

  # The case's setup is built first; only the command runs inside
  # events_written.
  def assert_row(kase)
    command = prepare(kase)
    written = events_written { assert_completed(command.call) }

    assert_equal kase.events, types(written) - SIDE, kase.name
    assert_equal kase.events.first, written.first.type, kase.name
  end

  # Builds what the case starts from and answers a lambda that runs it.
  def prepare(kase)
    case kase.command
    when "draft_contract"
      task = task_in(kase.from)
      -> { owner_command("draft_contract", { "id" => task.id }) }
    when "claim_job"
      waiting_contract(model_rule)
      -> { claim_job(@orchestrator) }
    when "submit_job_result"
      job = claimed_job
      -> { submit_result(@orchestrator, job, { "result" => "passed", "reason" => "Made-up reason." }) }
    else prepare_report(kase)
    end
  end

  def prepare_report(kase)
    job = claimed_job
    scenario.limit_credential(@grok, reset_at: from_now(900)) if kase.guard.include?("no_candidate_available")
    params = if kase.command == "report_job_limit"
      limit_params(@codex, @orchestrator, job_id: job.id, reset_at: from_now(400))
    else
      signed_out_params(@codex, @orchestrator, job_id: job.id)
    end
    -> { helper_command(kase.command, params) }
  end

  def task_in(from) = from == "finishing" ? scenario.finishing_task : scenario.task(state: from)

  def claimed_job
    _task, _pending, check = waiting_contract(model_rule)
    starting_attempts { assert_completed(claim_job(@orchestrator)) }
    job_of(check)
  end
end
