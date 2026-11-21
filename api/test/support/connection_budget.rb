require "etc"
require "tmpdir"

# How many connections the test suite may hold at once on the one
# PostgreSQL server its parallel workers share (max_connections, 100 by
# default). Each worker is a process with its own pool; a test that runs
# threads, a client program (pg_dump, createdb, psql, pg_restore) or
# bin/restore opens more. A worker that holds more than LIGHT at once
# does so only inside ConnectionBudget.heavy.
#
# The suite's worst case is need(workers); test/db/connection_budget_test.rb
# holds it under the server's max_connections.
module ConnectionBudget
  # The most workers the suite starts by itself, whatever the machine's
  # processor count; PARALLEL_WORKERS overrides it.
  MAXIMUM_WORKERS = 8
  # What one test outside heavy may hold at once in its worker: its own
  # connection, up to three threads' and two of a client program's or of
  # bin/restore's (the pool keeps the threads' connections open, idle,
  # after them).
  LIGHT = 6
  # What a test inside heavy may hold: twenty seats racing, a reader and
  # the test's own connection, and one to spare.
  HEAVY = 24
  # The parent process's: rails/test_help's schema check and the grants
  # test_helper applies before the workers start.
  PARENT = 2

  module_function

  # The lock heavy takes: a file every worker of the run opens, in the
  # container's temporary folder. The kernel lets it go when a worker dies.
  LOCK = File.join(Dir.tmpdir, "leverage-test-heavy.lock")

  # The number of workers the suite runs with: PARALLEL_WORKERS, else one
  # per processor, at most MAXIMUM_WORKERS.
  def workers
    return Integer(ENV["PARALLEL_WORKERS"], 10) if ENV["PARALLEL_WORKERS"]

    Etc.nprocessors.clamp(1, MAXIMUM_WORKERS)
  end

  # The connections the suite may hold at once with this many workers:
  # one worker inside heavy, every other at LIGHT, and the parent.
  def need(workers)
    ((workers - 1) * LIGHT) + HEAVY + PARENT
  end

  # Runs the block, which may hold up to HEAVY connections at once, while
  # no other worker of the run is inside heavy, and then closes the
  # connections its threads left idle in the pool (the pool keeps them
  # open otherwise, and the worker would go on holding them). threads is
  # how many it starts, each with a connection of its own. Returns the
  # block's value.
  def heavy(threads)
    raise ArgumentError, "#{threads} threads and the test's own connection pass HEAVY (#{HEAVY})" if threads + 1 > HEAVY

    File.open(LOCK, File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      begin
        yield
      ensure
        ActiveRecord::Base.connection_pool.flush!
      end
    end
  end
end
