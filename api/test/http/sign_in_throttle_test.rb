require "test_helper"

# Leverage::Http::SignInThrottle (PRD, Security): the owner's password is
# the only thing between a program that can reach the Mac's loopback
# address and the owner's session, so wrong passwords are counted and,
# after ten inside a minute, no password is compared until the minute has
# passed. The clock is the test's, so no test waits.
class SignInThrottleTest < ActiveSupport::TestCase
  Throttle = Leverage::Http::SignInThrottle

  setup do
    @now = 1_000.0
    @checks = 0
  end

  def check(answer)
    Throttle.check(clock: -> { @now }) do
      @checks += 1
      answer
    end
  end

  def fail_times(count) = count.times { assert_nil check(nil) }

  test "a check answers what its block answers" do
    assert_equal :owner, check(:owner)
    assert_nil check(nil)
  end

  test "after ten wrong passwords inside a minute the next check is refused without running" do
    fail_times(Throttle::LIMIT)

    assert_raises(Throttle::Blocked) { check(:owner) }
    assert_equal 10, @checks
  end

  test "nine wrong passwords leave the tenth check open, and a right password does not count" do
    fail_times(Throttle::LIMIT - 1)
    20.times { assert_equal :owner, check(:owner) }

    assert_nil check(nil)
    assert_raises(Throttle::Blocked) { check(:owner) }
  end

  test "the block ends when the oldest wrong password is a minute old" do
    fail_times(Throttle::LIMIT)
    @now += Throttle::WINDOW - 0.001
    assert_raises(Throttle::Blocked) { check(:owner) }

    @now += 0.002
    assert_equal :owner, check(:owner)
  end

  test "a refused check is not counted, so asking while blocked does not extend the block" do
    fail_times(Throttle::LIMIT)
    @now += 30
    5.times { assert_raises(Throttle::Blocked) { check(nil) } }

    @now += 30.001
    assert_nil check(nil)
  end

  # Sixty-four threads can each be comparing a password at once (Puma's
  # pool), so a check in progress holds one of the ten places.
  test "checks in progress count: ten at once leave no place for an eleventh" do
    started = Queue.new
    finish = Queue.new
    threads = Array.new(Throttle::LIMIT) do
      Thread.new do
        Throttle.check(clock: -> { @now }) do
          started << true
          finish.pop
          :owner
        end
      end
    end
    Throttle::LIMIT.times { started.pop }

    assert_raises(Throttle::Blocked) { check(:owner) }

    Throttle::LIMIT.times { finish << true }
    threads.each(&:join)
    assert_equal :owner, check(:owner)
  end

  test "a check that raises frees its place and is not counted as a wrong password" do
    Throttle::LIMIT.times { assert_raises(ArgumentError) { Throttle.check(clock: -> { @now }) { raise ArgumentError } } }

    assert_equal :owner, check(:owner)
  end

  test "a clock that steps back does not keep the block longer than a minute from then" do
    fail_times(Throttle::LIMIT)
    @now -= 3_600

    assert_equal :owner, check(:owner)
  end

  test "the wait message names no detail of the attempts" do
    fail_times(Throttle::LIMIT)

    error = assert_raises(Throttle::Blocked) { check(:owner) }
    assert_equal "Too many wrong sign-ins. Wait a minute and try again", error.message
  end
end
