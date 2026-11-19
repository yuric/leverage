require "test_helper"

# Leverage::LongPoll (PRD L217; milestone 2 plan §2.1, EN-21): it looks,
# waits, and looks again until something is found or the wait is over,
# giving its database connection back between looks. The look, the clock,
# the sleep and the release are the test's, so no test sleeps.
class LongPollTest < ActiveSupport::TestCase
  # A clock that moves only when the poll sleeps.
  class FakeClock
    attr_reader :now, :sleeps

    def initialize
      @now = 0.0
      @sleeps = []
    end

    def sleep(seconds)
      @sleeps << seconds
      @now += seconds
    end
  end

  setup do
    @clock = FakeClock.new
    @log = []
  end

  def poll(wait, answers)
    Leverage::LongPoll.wait(wait, clock: -> { @clock.now }, sleeper: ->(seconds) { @log << :sleep; @clock.sleep(seconds) },
      release: -> { @log << :release }) do
      @log << :look
      answers.shift
    end
  end

  test "it answers as soon as a look finds something" do
    assert_equal :found, poll(30, [ nil, nil, :found, :later ])
    assert_equal [ 0.25, 0.25 ], @clock.sleeps
  end

  test "a first look that finds something answers at once" do
    assert_equal :found, poll(30, [ :found ])
    assert_equal [ :look ], @log
  end

  test "it gives up at the wait, never sleeping past it" do
    assert_nil poll(1.1, Array.new(100))
    assert_in_delta 1.1, @clock.sleeps.sum, 1e-9
    assert_equal [ 0.25, 0.25, 0.25, 0.25 ], @clock.sleeps.first(4)
    assert_in_delta 0.1, @clock.sleeps.last, 1e-9
  end

  test "a wait of zero looks once" do
    assert_nil poll(0, [ nil, :found ])
    assert_equal [ :look ], @log
  end

  test "the connection is given back between looks, never while looking" do
    poll(0.5, [ nil, nil, :found ])
    assert_equal %i[look release sleep look release sleep look], @log
  end

  test "the default interval is 250 ms" do
    assert_in_delta 0.25, Leverage::LongPoll::INTERVAL, 1e-9
  end
end
