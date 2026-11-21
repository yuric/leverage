require "test_helper"
require_relative "rule_support"

# Entries::RerunCheck (PRD L392, L400, L423; milestone 4 plan RD-42,
# RD-43): Run it again, for an errored check only. At any hook but before
# an agent starts it, the check runs again as a new attempt with a job of
# its own (check.queued, job.queued), and its check_error hold stays open
# until a result other than error arrives. An errored claim check has
# already lapsed its provisional claim: Run it again closes its hold and
# queues nothing, so the next claim checks afresh. Anything but an errored
# check is invalid_state.
class RerunCheckTest < ActiveSupport::TestCase
  include RuleSupport

  setup do
    use_scenario
    @builder = scenario.seat(role: "builder", credential: scenario.credential)
  end

  # A submit waiting on an errored check of a blocking rule, held with
  # check_error (trace 19, command 20's shape at before_ready).
  def errored_submit
    @rule = scenario.rule(hook: "task.before_submit")
    @task = scenario.task(state: "working", builder: @builder)
    @pending = scenario.pending_transition(@task, command: "submit", requester: @builder)
    @check = scenario.rule_check(@task, rule: @rule, result: "error", attempts: 2, pending: @pending)
    @hold = rule_hold(@task, "check_error", rule: @rule, check: @check)
  end

  # Through RuleChecks.queue_attempt, so check.queued names the job before
  # job.queued (trace 19, command 20; WP4's request 1).
  test "an errored check runs again as a new attempt with its own job; the hold stays open (trace 19, command 20; L400)" do
    errored_submit
    key = new_key

    calls = recording({ Leverage::RuleChecks => :queue_attempt }) do
      assert_completed(owner_command("rerun_check", { "id" => @check.id }, key: key))
    end

    queued = calls.fetch("RuleChecks.queue_attempt").sole
    assert_equal [ @check.id, { kind: "rule_check", seat_role: "orchestrator" } ], [ queued.arguments[1].id, queued.keywords ]
    assert_kind_of Leverage::Transitions::Context, queued.arguments[0]
    assert_equal key, queued.arguments[0].request.key
    events = written_by(key)
    assert_equal %w[check.queued job.queued], events.map(&:type)
    job = Job.find(events.last.subject_id)
    assert_equal [ job.id, 3 ], events.first.payload.values_at("job_id", "attempt_number")
    assert_equal [ "rule_check", @check.id, "queued", 3 ], [ job.target_kind, job.target_id, job.state, job.attempt_number ]
    assert_nil @hold.reload.closed_at, "check_error closes when the new result arrives, not now"
  end

  test "an errored claim check has its hold closed with run_again and nothing queued (RD-42, L392)" do
    rule = scenario.rule(hook: "task.before_claim")
    task = scenario.task(state: "ready")
    check = scenario.rule_check(task, rule: rule, result: "error", attempts: 2, subject: @builder)
    rule_hold(task, "check_error", rule: rule, check: check)
    key = new_key

    calls = recording({ Leverage::Jobs => :queue, Leverage::RuleChecks => :queue_attempt }) do
      assert_completed(owner_command("rerun_check", { "id" => check.id }, key: key))
    end

    assert(calls.values.all?(&:empty?), "nothing is queued")
    events = written_by(key)
    assert_equal %w[hold.closed inbox.resolved], events.map(&:type)
    assert_equal [ "check_error", rule.id ], events.first.payload.values_at("reason", "rule_id")
    assert_equal({ "choice" => "run_again" }, events.last.payload)
    assert_empty open_holds(task)
    assert_equal "error", check.reload.result, "the errored row keeps its result"
  end

  test "an errored claim check with no hold left to close is invalid_state" do
    rule = scenario.rule(hook: "task.before_claim")
    task = scenario.task(state: "ready")
    check = scenario.rule_check(task, rule: rule, result: "error", attempts: 2, subject: @builder)

    outcome, events = owner_run("rerun_check", { "id" => check.id })

    assert_refused("invalid_state", outcome)
    assert_empty events
  end

  test "a check that did not end in error is invalid_state and queues nothing (RD-43)" do
    rule = scenario.rule(hook: "task.before_submit")
    task = scenario.task(state: "working", builder: @builder)
    checks = [ scenario.rule_check(task, rule: rule, result: "failed", input_hash: "1" * 64),
               scenario.rule_check(task, rule: rule, result: "passed", input_hash: "2" * 64),
               scenario.rule_check(task, rule: rule, result: "withdrawn", input_hash: "3" * 64),
               scenario.rule_check(task, rule: rule, input_hash: "4" * 64) ]

    calls = recording({ Leverage::Jobs => :queue, Leverage::RuleChecks => :queue_attempt }) do
      checks.each do |check|
        outcome, events = owner_run("rerun_check", { "id" => check.id })
        assert_refused("invalid_state", outcome)
        assert_empty events
      end
    end
    assert(calls.values.all?(&:empty?))
  end

  test "a check of a cancelled task is invalid_state" do
    errored_submit
    @task.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil)

    outcome, = owner_run("rerun_check", { "id" => @check.id })

    assert_refused("invalid_state", outcome)
  end

  test "a check of another workspace is 404" do
    other = Scenario.new
    other.owner
    rule = other.rule
    check = other.rule_check(other.task(state: "working", builder: other.seat(role: "builder", credential: other.credential)),
      rule: rule, result: "error", attempts: 2)

    assert_raises(T::NotFound) { owner_command("rerun_check", { "id" => check.id }) }
  end
end
