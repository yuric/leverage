require "test_helper"
require_relative "entries/gated_flow_support"

# The re-run limit holds across a release and a new claim (PRD L422: a
# model-checked gate runs at most the limit's number of times per round
# on changed inputs; milestone 4 review, finding 2). A row held at the
# limit never ran; when its waiting command is ended (a release), the row
# is withdrawn, and meeting it again is not a retry of a run that
# happened: it is held again, and no job is queued.
class RerunLimitReleaseTest < ActiveSupport::TestCase
  include GatedFlowSupport

  REASON = "unable_to_continue".freeze

  setup do
    use_scenario
    @orchestrator = online_orchestrator
    @builder = scenario.seat(role: "builder")
    @rule = model_rule(hook: "task.before_submit")
    @task = ready_to_submit(@builder)
  end

  def rule_check_jobs = Job.where(workspace_id: scenario.workspace_id, kind: "rule_check").count

  def submit_note(note)
    acknowledge(@builder, @task)
    seat_command(@builder, "submit", submit_body(@task, note: note))
  end

  test "a fourth input held at the limit, released and submitted again after a new claim, is held again" do
    3.times do |run|
      assert_equal :pending, submit_note("Made-up note #{run}.").outcome
      answer_next(@orchestrator, FAILED)
    end
    assert_equal :pending, submit_note("Made-up note 3.").outcome
    assert_equal [ "rerun_limit" ], open_holds(@task).map(&:reason)
    assert_equal 3, rule_check_jobs

    assert_completed(seat_command(@builder, "release", { "id" => @task.id, "reason" => REASON }))
    assert_equal [ "ready", [] ], [ @task.reload.state, open_holds(@task) ]
    assert_completed(seat_command(@builder, "claim"))
    assert_equal [ "working", 0 ], [ @task.reload.state, @task.round ]

    assert_equal :pending, submit_note("Made-up note 3.").outcome

    assert_equal 3, rule_check_jobs, "no fourth run is queued"
    assert_equal [ "rerun_limit" ], open_holds(@task.reload).map(&:reason)
    held = RuleCheck.find(open_holds(@task).sole.rule_check_id)
    assert_nil held.result
    assert_empty RuleCheckAttempt.where(rule_check_id: held.id).where.not(job_id: nil)
  end

  test "a check that ran and was withdrawn is run again on the same inputs at the limit" do
    3.times do |run|
      assert_equal :pending, submit_note("Made-up note #{run}.").outcome
      answer_next(@orchestrator, FAILED) unless run == 2
    end
    assert_equal 3, rule_check_jobs
    assert_completed(seat_command(@builder, "release", { "id" => @task.id, "reason" => REASON }))
    assert_completed(seat_command(@builder, "claim"))

    assert_equal :pending, submit_note("Made-up note 2.").outcome

    assert_equal 4, rule_check_jobs, "the third run, withdrawn, is retried: its hash is one of the three"
    assert_empty open_holds(@task.reload)
  end
end
