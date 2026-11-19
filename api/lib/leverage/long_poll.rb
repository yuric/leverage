module Leverage
  # A long poll (PRD L217; milestone 2 plan §2.1, EN-21): it waits outside
  # any transaction, looking again every 250 ms, and gives its database
  # connection back to the pool between looks, so a waiting call holds no
  # connection while it sleeps. The look, the clock, the sleep and the
  # release are parameters, so its timing is tested without a database.
  module LongPoll
    INTERVAL = 0.25

    module_function

    # Looks until the block answers something truthy or `seconds` have
    # passed, and returns the answer, or nil. A wait of zero looks once.
    def wait(seconds, interval: INTERVAL, clock: method(:monotonic), sleeper: method(:sleep_for),
             release: method(:release_connection))
      deadline = clock.call + seconds
      loop do
        found = yield
        return found if found

        now = clock.call
        return nil if now >= deadline

        release.call
        sleeper.call([ interval, deadline - now ].min)
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def sleep_for(seconds) = Kernel.sleep(seconds)

    # Gives the connection back, unless a transaction holds it (a test's
    # own transaction: that connection is the test's).
    def release_connection
      pool = ActiveRecord::Base.connection_pool
      connection = pool.active_connection?
      return if connection && connection.transaction_open?

      pool.release_connection
    end
  end
end
