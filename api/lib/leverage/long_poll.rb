module Leverage
  # A long poll (PRD L217; milestone 2 plan §2.1, EN-21): it waits outside
  # any transaction, looking again every 250 ms, and gives its database
  # connection back to the pool between looks, so a waiting call holds no
  # connection while it sleeps. The look, the clock, the sleep and the
  # release are parameters, so its timing is tested without a database.
  #
  # A waiting call does hold its thread of the server's pool. A caller
  # named by `key` (a seat or the helper) therefore has one waiting poll
  # at a time: a newer one with the same key ends the older, which answers
  # nothing when it wakes, within one interval, and does not look again.
  # The newer one wins so that a caller whose earlier request was dropped
  # on its side waits again at once instead of being answered at once,
  # over and over, until the dropped one's time is up. The keys are kept
  # in this process, one for each waiting caller.
  module LongPoll
    INTERVAL = 0.25

    @mutex = Mutex.new
    @turns = {}

    module_function

    # Looks until the block answers something truthy or `seconds` have
    # passed, and returns the answer, or nil. A wait of zero looks once,
    # and ends no other poll.
    def wait(seconds, key: nil, interval: INTERVAL, clock: method(:monotonic), sleeper: method(:sleep_for),
             release: method(:release_connection))
      turn = take_turn(key) if key && seconds.positive?
      deadline = clock.call + seconds
      loop do
        found = yield
        return found if found

        now = clock.call
        return nil if now >= deadline || ended?(key, turn)

        release.call
        sleeper.call([ interval, deadline - now ].min)
        return nil if ended?(key, turn)
      end
    ensure
      give_turn_back(key, turn)
    end

    # Whether a poll with the key is waiting.
    def waiting?(key) = @mutex.synchronize { @turns.key?(key) }

    def take_turn(key)
      turn = Object.new
      @mutex.synchronize { @turns[key] = turn }
      turn
    end

    # Whether a newer poll took the key from this one.
    def ended?(key, turn) = !turn.nil? && @mutex.synchronize { !@turns[key].equal?(turn) }

    def give_turn_back(key, turn)
      return if turn.nil?

      @mutex.synchronize { @turns.delete(key) if @turns[key].equal?(turn) }
    end
    private_class_method :take_turn, :ended?, :give_turn_back

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
