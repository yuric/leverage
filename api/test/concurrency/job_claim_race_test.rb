require "test_helper"

# Concurrency for jobs (PRD test 6; milestone 4 plan §1.1 "model check
# jobs", WP12): twenty orchestrators claim at once and no job is claimed
# twice. Each claim runs on a connection of its own and commits
# (CommittingTestCase); the workspace lock (DB-4) is what keeps two claims
# from taking one job. The test reads what the claimers committed with the
# query cache off, as ClaimRaceTest does.
class JobClaimRaceTest < CommittingTestCase
  T = Leverage::Transitions

  # The rows the claimers committed that other files' tests count across
  # the worker's database are deleted again (events cannot be, and stay):
  # commands rows (transitions_pipeline_test.rb) and the jobs with their
  # checks (claim_job_test.rb and draft_contract_test.rb count the
  # scenario's jobs, and the timers' committing cases sweep every job).
  teardown do
    ActiveRecord::Base.uncached do
      Command.where(workspace_id: scenario.workspace_id).delete_all
      RuleCheckAttempt.where(workspace_id: scenario.workspace_id).delete_all
      Job.where(workspace_id: scenario.workspace_id).delete_all
    end
  end

  SEATS = 20
  JOBS = 10

  # Runs the block on one thread per item, each on a connection of its
  # own, released together once all are ready. Returns the blocks' values.
  def at_once(items)
    pool = ActiveRecord::Base.connection_pool
    assert_operator pool.size, :>, items.size, "the pool (DB_POOL) must hold every claimer and the test"
    ready = Concurrent::CountDownLatch.new(items.size)
    go = Concurrent::CountDownLatch.new(1)
    threads = items.map do |item|
      Thread.new do
        pool.with_connection do
          ready.count_down
          go.wait
          yield item
        end
      end
    end
    ready.wait(30)
    go.count_down
    threads.map(&:value)
  end

  def claim_job(seat)
    T.apply(T::Request.new(command: "claim_job", workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
      key: "job-race-#{seat.id}", request_hash: "j" * 64, params: {}))
  end

  # JOBS queued rule check jobs, one per task, each the first attempt of a
  # blocking model check (Scenario#rule_check).
  def queued_jobs
    rule = scenario.rule(hook: "task.before_submit")
    Array.new(JOBS) do
      task = scenario.task(state: "working")
      check = scenario.rule_check(task, rule: rule)
      Job.find(RuleCheckAttempt.find_by!(rule_check_id: check.id).job_id)
    end
  end

  test "twenty orchestrators claim at once and no job is claimed twice" do
    jobs = queued_jobs
    seats = Array.new(SEATS) { scenario.orchestrator }

    outcomes = at_once(seats) { |seat| claim_job(seat) }

    ActiveRecord::Base.uncached do
      assert_equal JOBS, outcomes.count(&:completed?)
      assert_equal [ "not_eligible" ] * (SEATS - JOBS), outcomes.select(&:refused?).map { |outcome| outcome.refusal.code }
      claimed = Event.where(workspace_id: scenario.workspace_id, type: "job.claimed").pluck(:subject_id)
      assert_equal jobs.map(&:id).sort, claimed.sort, "each job is claimed exactly once"
      rows = Job.where(id: jobs.map(&:id)).pluck(:state, :claimed_by_seat_id)
      assert_equal [ "claimed" ] * JOBS, rows.map(&:first)
      assert_equal JOBS, rows.map(&:last).uniq.size, "no seat holds two jobs"
      outcomes.zip(seats).select { |outcome, _| outcome.completed? }.each do |outcome, seat|
        assert_equal seat.id, Job.find(outcome.result.fetch("job_id")).claimed_by_seat_id
      end
      started = Event.where(workspace_id: scenario.workspace_id, type: "check.started").count
      assert_equal JOBS, started, "each check's attempt starts once"
    end
  end
end
