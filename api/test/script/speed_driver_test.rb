require "test_helper"
load Rails.root.join("script/speed/run.rb").to_s

# The speed run's driver (script/speed/run.rb). Agents are separate
# programs that each heartbeat on their own clock, so the driver's seats
# must not all tick at the same instant: fifty seats that do would queue
# every command of a tick behind one another for the workspace lock and
# leave it idle for the rest of the tick, and the run would measure that
# queue instead of the server (F2, milestone 2).
class SpeedDriverTest < ActiveSupport::TestCase
  class FakeOwner
    attr_reader :calls

    def initialize
      @calls = []
      @last_seat = 0
    end

    def call(operation, ids: {}, body:)
      @calls << [ operation, ids, body["connection"] ]
      case operation
      when "connect_seat"
        @last_seat += 1
        [ 200, { "result" => { "seat_id" => "seat-#{@last_seat}" } } ]
      when "issue_landing_prompt"
        [ 200, { "result" => { "seat_id" => ids.fetch("id"), "connection" => "http",
                              "seat_token" => "fake-token-#{@last_seat}", "text" => "fake landing prompt" } } ]
      end
    end
  end

  test "each connected seat gets its token from its HTTP landing prompt without printing it" do
    setup = Speed::Setup.new(Speed::Options.new(url: "http://example.test", seats: 2), Speed::Tally.new)
    owner = FakeOwner.new
    setup.instance_variable_set(:@owner, owner)

    assert_output("", "") { setup.send(:connect_seats) }

    assert_equal [ [ "connect_seat", {}, nil ], [ "issue_landing_prompt", { "id" => "seat-1" }, "http" ],
                   [ "connect_seat", {}, nil ], [ "issue_landing_prompt", { "id" => "seat-2" }, "http" ] ], owner.calls
    assert_equal [ [ :builder, "fake-token-1" ], [ :reviewer, "fake-token-2" ] ], setup.seats
  rescue SystemExit => error
    flunk error.message
  end

  # Production answers only a request addressed to loopback (config.hosts),
  # so the driver, which reaches the API by its compose name, must not send
  # that name as Host.
  test "every call is addressed to loopback, whatever name the driver reaches the API by" do
    client = Speed::Client.new("http://api:3000", Speed::Tally.new, token: "fake-token")
    sent = []
    reply = Struct.new(:code, :body).new("200", "{}")
    client.define_singleton_method(:send_request) { |request| sent << request and reply }

    client.call("get_health")
    client.call("connect_seat", body: {})

    assert_equal [ "127.0.0.1:3000", "127.0.0.1:3000" ], sent.map { |request| request["Host"] }
  end

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
