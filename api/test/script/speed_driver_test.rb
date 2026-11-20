require "test_helper"
load Rails.root.join("script/speed/run.rb").to_s

# The speed run's driver (script/speed/run.rb). Agents are separate
# programs that each heartbeat on their own clock, so the driver's seats
# must not all tick at the same instant: fifty seats that do would queue
# every command of a tick behind one another for the workspace lock and
# leave it idle for the rest of the tick, and the run would measure that
# queue instead of the server (F2, milestone 2).
class SpeedDriverTest < ActiveSupport::TestCase
  test "the seats' first ticks are spread evenly over one tick, in the order they connected" do
    assert_equal [ 100.0, 100.5, 101.0, 101.5 ], Speed.seat_starts(100.0, seats: 4, tick: 2.0)
  end

  test "no two of fifty seats start together and every one starts within the first tick" do
    starts = Speed.seat_starts(10.0, seats: 50, tick: 2.0)

    assert_equal 50, starts.uniq.size
    assert starts.all? { |at| at >= 10.0 && at < 12.0 }, "a seat starts outside the first tick: #{starts.inspect}"
    assert_in_delta 0.04, starts[1] - starts[0], 1e-9
  end
end
