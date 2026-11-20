require "test_helper"
require_relative "../support/trace_runner"

# Track F's queries on golden-trace logs (PRD L315 to L318; milestone 4
# plan RT-7): Reads::RuleTiming per rule, with the answers worked out by
# hand from the trace's times, read in the engine's clock as
# TaskTimelineQueryTest reads them. A job timer runs at its job's due time
# because the runner puts the job's queued (or started) time one timeout
# before it (EN-18), so an attempt that waited out its queue timeout waited
# exactly that long in the engine too.
class RuleTimingQueryTest < ActiveSupport::TestCase
  R = Leverage::Reads::RuleTiming
  QUEUE_TIMEOUT = 120

  def run_trace(name)
    TraceRunner.new(name).run.tap { |runner| assert_empty runner.failures, runner.failures.join("\n") }
  end

  def rule_row(runner, key, as_of)
    rule = Rule.find_by!(workspace_id: runner.workspace_id, key: key)
    R.call(runner.workspace_id, rule_id: rule.id, as_of: as_of).sole
  end

  # Trace 07: the specific-details check's two attempts each waited 120 s
  # in the queue and never ran; it held the task up from its first
  # attempt's queued time to its error at 250, then 150 s more while the
  # owner held it under check_error (250 to 400). Its first attempt was
  # due at 130, so it was queued 120 s before 130's instant.
  test "trace 07: two attempts of 120 s in the queue that never ran, and the time the rule held the task up" do
    runner = run_trace("07-pending-gate-check-error-override")
    as_of = runner.instant(500)
    row = rule_row(runner, "specific_details", as_of)

    assert_equal 2, row.fetch("attempts")
    assert_in_delta 2 * QUEUE_TIMEOUT, row.fetch("queue_seconds"), 0.000_001
    assert_in_delta QUEUE_TIMEOUT, row.fetch("average_queue_seconds"), 0.000_001
    assert_in_delta 0, row.fetch("run_seconds"), 0.000_001
    assert_nil row.fetch("average_run_seconds")
    assert_equal({ "error" => 1 }, row.fetch("results"))
    assert_equal [ 1, 0, 0.0 ], row.values_at("overrides", "tokens", "spend")
    first_queued = runner.instant(130).to_r - QUEUE_TIMEOUT
    blocked = runner.instant(250).to_r - first_queued
    owner = runner.instant(400).to_r - runner.instant(250).to_r
    assert_in_delta (blocked + owner).to_f, row.fetch("held_up_seconds"), 0.000_001

    criteria = rule_row(runner, "acceptance_criteria", as_of)
    assert_equal [ 1, { "passed" => 1 }, 0.0, 0.0, 0.0 ],
      criteria.values_at("attempts", "results", "queue_seconds", "run_seconds", "held_up_seconds")
  end

  # Trace 16: specific details runs three times; each attempt is claimed
  # and answered (10 to 20 and 20 to 50; 100 to 110 and 110 to 140; 300 to
  # 310 and 310 to 340), 400 tokens each, and its first answer failed.
  test "trace 16: three attempts, each claimed after 10 s and answered after 30, with their tokens" do
    runner = run_trace("16-model-gate-and-draft")
    row = rule_row(runner, "specific_details", runner.instant(410))
    span = ->(from, to) { runner.instant(to).to_r - runner.instant(from).to_r }

    assert_equal 3, row.fetch("attempts")
    assert_in_delta (span.call(10, 20) + span.call(100, 110) + span.call(300, 310)).to_f, row.fetch("queue_seconds"), 0.000_001
    assert_in_delta (span.call(20, 50) + span.call(110, 140) + span.call(310, 340)).to_f, row.fetch("run_seconds"), 0.000_001
    assert_equal({ "failed" => 1, "passed" => 2 }, row.fetch("results"))
    tokens = Job.where(workspace_id: runner.workspace_id, kind: "rule_check").sum(:tokens)
    assert_equal tokens, row.fetch("tokens")
    assert_operator tokens, :>, 0
  end
end
