require "test_helper"

# The suite's connections fit the server (ConnectionBudget): every worker
# shares one PostgreSQL server, and a run that passes its max_connections
# fails a test at random with "FATAL: sorry, too many clients already"
# (20 workers on a 20-processor Mac with twenty-thread race tests did).
# These tests touch no row, and run outside a transaction so that a
# thread's connection is its own and not the test's pinned one.
class ConnectionBudgetTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setting(name) = Integer(ActiveRecord::Base.lease_connection.select_value("SHOW #{name}"), 10)

  test "the suite's worst case fits under the server's max_connections, less the reserved slots" do
    available = setting("max_connections") - setting("superuser_reserved_connections") - setting("reserved_connections")
    workers = ConnectionBudget.workers

    assert_operator ConnectionBudget.need(workers), :<=, available,
      "#{workers} workers may hold #{ConnectionBudget.need(workers)} connections; the server takes #{available}"
  end

  test "the workers are capped whatever the processor count, and PARALLEL_WORKERS still wins" do
    saved = ENV.delete("PARALLEL_WORKERS")
    assert_operator ConnectionBudget.workers, :<=, ConnectionBudget::MAXIMUM_WORKERS
    assert_operator ConnectionBudget.workers, :>=, 1
    ENV["PARALLEL_WORKERS"] = "3"
    assert_equal 3, ConnectionBudget.workers
  ensure
    saved ? ENV["PARALLEL_WORKERS"] = saved : ENV.delete("PARALLEL_WORKERS")
  end

  test "two heavy sections never run at once, in one process or in two" do
    spans = Queue.new
    section = lambda do
      ConnectionBudget.heavy(1) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep 0.3
        spans << [ started, Process.clock_gettime(Process::CLOCK_MONOTONIC) ]
      end
    end
    [ Thread.new(&section), Thread.new(&section) ].each(&:join)

    first, second = Array.new(2) { spans.pop }.sort
    assert_operator second.first, :>=, first.last, "the second section started before the first ended"
  end

  test "a heavy section leaves its threads' connections closed, not idle in the pool" do
    pool = ActiveRecord::Base.connection_pool
    own = ActiveRecord::Base.lease_connection

    ConnectionBudget.heavy(5) do
      ready = Concurrent::CountDownLatch.new(5)
      Array.new(5) do
        Thread.new do
          pool.with_connection do |connection|
            connection.select_value("SELECT 1")
            ready.count_down
            ready.wait(10)
          end
        end
      end.each(&:join)
    end

    # Only the test's own connection is left: an earlier test's idle one
    # in this worker's pool is closed too.
    assert_equal [ own ], pool.connections, "the pool still holds the threads' connections after the section"
  end

  test "a section that would pass HEAVY is refused before it starts" do
    assert_raises(ArgumentError) { ConnectionBudget.heavy(ConnectionBudget::HEAVY) { flunk "it ran" } }
  end
end
