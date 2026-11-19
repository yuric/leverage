require "test_helper"

# Concurrency, first half (PRD test 6; milestone 2 plan TS-10, EN-26):
# twenty seats claim at once and no task is claimed twice. Each claim runs
# on a connection of its own and commits (CommittingTestCase); the
# workspace lock (DB-4) is what keeps two claims from taking one task.
# The test reads what the claimers committed with the query cache off: the
# test's own cache would answer with the rows as they were before the race.
class ClaimRaceTest < CommittingTestCase
  T = Leverage::Transitions
  SEATS = 20
  TASKS = 10

  # Runs the block on SEATS threads, each on a connection of its own,
  # released together once all are ready. Returns the blocks' values.
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

  def claim(seat)
    T.apply(T::Request.new(command: "claim", workspace_id: scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
      key: "race-#{seat.id}", request_hash: "c" * 64, params: {}))
  end

  test "twenty seats claim at once and no task is claimed twice" do
    credential = scenario.credential
    seats = Array.new(SEATS) { scenario.seat(role: "builder", credential: credential) }
    tasks = Array.new(TASKS) { scenario.task(state: "ready") }

    outcomes = at_once(seats) { |seat| claim(seat) }

    ActiveRecord::Base.uncached { assert_one_claim_each(outcomes, seats, tasks) }
  end

  def assert_one_claim_each(outcomes, seats, tasks)
    assert_equal TASKS, outcomes.count(&:completed?)
    assert_equal [ "not_eligible" ] * (SEATS - TASKS), outcomes.select(&:refused?).map { |outcome| outcome.refusal.code }
    claimed = Event.where(workspace_id: scenario.workspace_id, type: "task.claimed").pluck(:task_id)
    assert_equal tasks.map(&:id).sort, claimed.sort, "each task is claimed exactly once"
    holders = Task.where(id: tasks.map(&:id)).pluck(:state, :holder_seat_id)
    assert_equal [ "working" ] * TASKS, holders.map(&:first)
    assert_equal TASKS, holders.map(&:last).uniq.size, "no seat holds two tasks"
    winners = outcomes.zip(seats).select { |outcome, _| outcome.completed? }
    winners.each do |outcome, seat|
      assert_equal seat.id, Task.find(outcome.result.dig("task", "id")).holder_seat_id
    end
  end

  test "the seqs of the race's events are one unbroken run, in commit order" do
    credential = scenario.credential
    seats = Array.new(SEATS) { scenario.seat(role: "builder", credential: credential) }
    Array.new(TASKS) { scenario.task(state: "ready") }
    before = scenario.workspace.reload.last_seq

    at_once(seats) { |seat| claim(seat) }

    seqs = ActiveRecord::Base.uncached do
      Event.where(workspace_id: scenario.workspace_id).where("seq > ?", before).order(:seq).pluck(:seq, :at)
    end
    assert_equal ((before + 1)..(before + TASKS)).to_a, seqs.map(&:first)
    assert_equal seqs.map(&:last).sort, seqs.map(&:last), "a later seq never has an earlier at"
  end
end
