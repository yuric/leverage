require "test_helper"

# Concurrency, second half (PRD test 6, L839-L841; milestone 2 plan TS-10,
# EN-26): while twenty claimers commit, a reader on a connection of its own
# tails the log through Reads::EventsTail, passing back next_after_seq. It
# never sees a number lower than one it has seen, and when the writers are
# done its list has every seq from first to last with none missing, so no
# gap was left to fill later.
class SeqTailTest < CommittingTestCase
  T = Leverage::Transitions
  SEATS = 20
  PAGE = 3

  def apply(seat, command, params, key)
    T.apply(T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end

  # Each seat claims a task and acknowledges its briefing: two commits,
  # two events.
  def work(seat)
    claim = apply(seat, "claim", {}, "tail-claim-#{seat.id}")
    return [ claim ] unless claim.completed?

    task = Task.find(claim.result.dig("task", "id"))
    [ claim, apply(seat, "acknowledge_briefing", { "id" => task.id, "briefing_hash" => Leverage::Briefing.hash_for(task, seat) },
      "tail-ack-#{seat.id}") ]
  end

  test "a reader tailing by seq while twenty claimers commit never goes back and never sees a gap fill" do
    credential = scenario.credential
    seats = Array.new(SEATS) { scenario.seat(role: "builder", credential: credential) }
    Array.new(SEATS) { scenario.task(state: "ready") }
    start = scenario.workspace.reload.last_seq
    pool = ActiveRecord::Base.connection_pool
    assert_operator pool.size, :>, SEATS + 1, "the pool (DB_POOL) must hold every claimer, the reader and the test"

    done = Concurrent::AtomicBoolean.new(false)
    go = Concurrent::CountDownLatch.new(1)
    seen = []
    problems = []
    reader = Thread.new do
      pool.with_connection do
        cursor = start
        go.wait
        loop do
          writers_done = done.true?
          page = Leverage::Reads::EventsTail.call(scenario.workspace_id, after_seq: cursor, limit: PAGE)
          numbers = page.fetch(:events).map { |event| event.fetch(:seq) }
          problems << "after #{cursor} the page went back: #{numbers}" if numbers.any? { |number| number <= cursor }
          problems << "the page is out of order: #{numbers}" unless numbers == numbers.sort
          problems << "next_after_seq #{page.fetch(:next_after_seq)} is behind #{cursor}" if page.fetch(:next_after_seq) < cursor
          seen.concat(numbers)
          cursor = page.fetch(:next_after_seq)
          break if writers_done && numbers.empty?

          sleep 0.002 if numbers.empty?
        end
      end
    end
    writers = seats.map do |seat|
      Thread.new do
        pool.with_connection do
          go.wait
          work(seat)
        end
      end
    end
    go.count_down
    outcomes = writers.flat_map(&:value)
    done.make_true
    reader.join(60)

    assert_equal SEATS * 2, outcomes.count(&:completed?)
    assert_empty problems
    # Uncached: the test's query cache holds the workspace row as it was
    # before the writers.
    last = ActiveRecord::Base.uncached { scenario.workspace.reload.last_seq }
    assert_equal ((start + 1)..last).to_a, seen, "the reader saw every seq once, in order, with none missing"
    assert_equal start + (SEATS * 2), last
  end
end
