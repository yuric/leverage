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

  # One waiting poll for each caller (a seat or the helper): a thread of
  # the pool is held while a poll sleeps, so a caller that opened many
  # would hold them all. A newer waiting poll with the same key ends the
  # older one. A poll inside another's sleep stands for a second request.
  def nested(outer_key:, inner_key:, inner_wait: 30)
    looks = { outer: 0, inner: 0 }
    started = false
    sleeper = lambda do |seconds|
      unless started
        started = true
        Leverage::LongPoll.wait(inner_wait, key: inner_key, clock: -> { @clock.now },
          sleeper: ->(inner) { @clock.sleep(inner) }, release: -> { }) do
          looks[:inner] += 1
          nil
        end
      end
      @clock.sleep(seconds)
    end
    answer = Leverage::LongPoll.wait(60, key: outer_key, clock: -> { @clock.now }, sleeper: sleeper, release: -> { }) do
      looks[:outer] += 1
      looks[:outer] > 1 ? :found_later : nil
    end
    [ answer, looks ]
  end

  test "a newer waiting poll with the same key ends the older one, which answers nothing and does not look again" do
    answer, looks = nested(outer_key: "seat:1", inner_key: "seat:1")

    assert_nil answer
    assert_equal 1, looks[:outer]
    assert_operator looks[:inner], :>, 100, "the newer poll waits out its own time"
    assert_in_delta 30.25, @clock.now, 1e-6, "the older one ends when it wakes, long before its 60 seconds"
  end

  test "a poll with another key, or with none, leaves a waiting poll alone" do
    assert_equal [ :found_later, { outer: 2, inner: 121 } ], nested(outer_key: "seat:1", inner_key: "seat:2")
    assert_equal [ :found_later, { outer: 2, inner: 121 } ], nested(outer_key: "seat:1", inner_key: nil)
    assert_equal [ :found_later, { outer: 2, inner: 121 } ], nested(outer_key: nil, inner_key: "seat:1")
    assert_equal [ :found_later, { outer: 2, inner: 121 } ], nested(outer_key: nil, inner_key: nil)
  end

  test "a look that does not wait ends no waiting poll" do
    assert_equal [ :found_later, { outer: 2, inner: 1 } ], nested(outer_key: "seat:1", inner_key: "seat:1", inner_wait: 0)
  end

  test "a key is waiting only while its poll waits, also when a look raises" do
    seen = []
    Leverage::LongPoll.wait(1, key: "seat:1", clock: -> { @clock.now }, release: -> { },
      sleeper: ->(seconds) { seen << Leverage::LongPoll.waiting?("seat:1") and @clock.sleep(seconds) }) { nil }
    assert_equal [ true ] * 4, seen
    refute Leverage::LongPoll.waiting?("seat:1")

    assert_raises(ArgumentError) do
      Leverage::LongPoll.wait(1, key: "seat:1", clock: -> { @clock.now }, sleeper: ->(_) { }, release: -> { }) { raise ArgumentError }
    end
    refute Leverage::LongPoll.waiting?("seat:1")
  end

  # Two requests of one caller, each on its own thread, as in the server.
  test "the poll that was ended does not take the key away from the one that ended it" do
    asleep = { older: Queue.new, newer: Queue.new }
    wake = { older: Queue.new, newer: Queue.new }
    time = { older: 0.0, newer: 0.0 }
    poll = lambda do |name|
      Thread.new do
        Leverage::LongPoll.wait(60, key: "seat:1", clock: -> { time[name] }, release: -> { },
          sleeper: ->(_) { asleep[name] << true and wake[name].pop }) { nil }
      end
    end
    older = poll.call(:older)
    asleep[:older].pop
    newer = poll.call(:newer)
    asleep[:newer].pop

    wake[:older] << true
    assert_nil older.value
    assert Leverage::LongPoll.waiting?("seat:1"), "the newer poll still waits"

    time[:newer] = 60.0
    wake[:newer] << true
    assert_nil newer.value
    refute Leverage::LongPoll.waiting?("seat:1")
  end

  test "the default interval is 250 ms" do
    assert_in_delta 0.25, Leverage::LongPoll::INTERVAL, 1e-9
  end
end
