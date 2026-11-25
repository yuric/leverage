require "test_helper"

# The two long polls over HTTP, GET /v1/next and GET /v1/helper/next
# (milestone 2 plan WP8, §2.1 long_poll.rb, EN-21): they wait outside any
# transaction and give their database connection back between looks, so a
# waiting call holds no connection while it sleeps. A transaction of the
# test's own would prove nothing here, so this is a CommittingTestCase:
# every write commits before the next look.
#
# Rails (7.2 on) leases a connection for the length of a query unless the
# thread holds one for good (lease_connection, an open transaction), so the
# busy count that matters is the one at the sleep: the test thread holds a
# lease when the poll starts (Scenario reads the clock with lease_connection)
# and LongPoll gives it back before the first sleep.
#
# The contract's wait is whole seconds, so the half second these tests wait
# is put in by wrapping LongPoll.wait for the call. LongPoll's own timing is
# WP1's unit test; nothing here sleeps while a writer catches up: a write
# that should be seen by the next look is made from the sleeper, which runs
# between two looks.
class LongPollHttpTest < CommittingTestCase
  include ActionDispatch::IntegrationTest::Behavior
  include OpenapiAssertions

  # Eligibility's and Briefing's answers, scripted: nothing is waiting and
  # the briefing's hash never changes (WP3's own are not under test here).
  class Waiting
    def next_task(_seat) = nil
    def next_review(_seat) = nil
  end

  class Hashing
    def hash_for(_subject, _seat) = "made-up-hash"
  end

  setup do
    @builder = scenario.seat(role: "builder")
    @helper = scenario.helper
  end

  # Wraps Leverage::LongPoll.wait for the block: waits `seconds`, notes the
  # pool's busy count before each look and at each sleep, calls between at every
  # sleep and sleeps for real only when sleep is true. Returns the samples.
  def probing(seconds: 0.5, sleep: true, between: nil)
    samples = { looks: [], sleeps: [] }
    original = Leverage::LongPoll.method(:wait)
    Leverage::LongPoll.define_singleton_method(:wait) do |_requested, **options, &look|
      pool = ActiveRecord::Base.connection_pool
      sleeper = lambda do |interval|
        samples[:sleeps] << pool.stat[:busy]
        between&.call
        Kernel.sleep(interval) if sleep
      end
      noted = lambda do
        samples[:looks] << pool.stat[:busy]
        look.call
      end
      original.call(seconds, **options, sleeper: sleeper, &noted)
    end
    yield samples
    samples
  ensure
    Leverage::LongPoll.define_singleton_method(:wait, original)
  end

  def call(path, token)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Leverage::Reads::NextItem.with_collaborators(eligibility: Waiting.new, briefing: Hashing.new) do
      get path, headers: { "Authorization" => "Bearer #{token}" }
    end
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  test "GET /v1/next waits out its time with nothing to say and gives its connection back between looks" do
    elapsed = nil
    samples = probing { elapsed = call("/v1/next?wait=30", scenario.token_for(@builder)) }

    assert_response :ok
    assert_equal({ "kind" => "none", "id" => nil, "review_id" => nil }, response.parsed_body)
    assert_response_matches_contract
    assert_operator elapsed, :>=, 0.4
    assert_operator elapsed, :<, 5
    assert_operator samples[:looks].size, :>=, 2
    assert_operator samples[:looks].first, :>=, 1, "the test's own connection is leased when the poll starts"
    assert_equal [ 0 ] * (samples[:looks].size - 1), samples[:looks].drop(1), "and not leased again before any later look"
    assert_equal [ 0 ] * samples[:sleeps].size, samples[:sleeps], "no connection is held while the poll sleeps"
    assert_operator samples[:sleeps].size, :>=, 1
  end

  test "GET /v1/next answers at the look that finds an item, which a write made between two looks put there" do
    task = scenario.task(state: "working", builder: @builder)
    written = false
    between = lambda do
      next if written

      written = true
      task.update_columns(resume_pending_since: scenario.database_now)
    end
    samples = probing(sleep: false, between: between) { call("/v1/next?wait=30", scenario.token_for(@builder)) }

    assert_response :ok
    assert_equal({ "kind" => "resume", "id" => task.id, "review_id" => nil }, response.parsed_body)
    assert_response_matches_contract
    assert_equal 2, samples[:looks].size
    assert_equal [ 0 ], samples[:sleeps]
  end

  test "GET /v1/next ends with 401 at the look after the seat was removed while it waited" do
    seat = scenario.seat(role: "builder")
    token = scenario.token_for(seat)
    probing(sleep: false, between: -> { scenario.remove(seat) }) { call("/v1/next?wait=30", token) }

    assert_response :unauthorized
    assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
  end

  test "GET /v1/next ends with 401 when the seat's token is replaced while it waits" do
    seat = scenario.seat(role: "builder")
    token = scenario.token_for(seat)
    probing(sleep: false, between: -> { scenario.end_token(seat) }) { call("/v1/next?wait=30", token) }

    assert_response :unauthorized
    assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
  end

  test "GET /v1/helper/next waits and gives its connection back between looks, and answers with null" do
    samples = probing { call("/v1/helper/next?wait=30", scenario.helper_token) }

    assert_response :ok
    assert_equal({ "request" => nil }, response.parsed_body)
    assert_response_matches_contract
    assert_equal [ 0 ] * samples[:sleeps].size, samples[:sleeps]
    assert_operator samples[:sleeps].size, :>=, 1
    assert_operator samples[:looks].first, :>=, 1
  end

  test "GET /v1/helper/next picks up the request that a write made between two looks put in the queue" do
    request = nil
    between = lambda do
      request ||= HelperRequest.create!(workspace_id: scenario.workspace_id, kind: "verify", state: "queued",
        requested_at: scenario.database_now)
    end
    probing(sleep: false, between: between) { call("/v1/helper/next?wait=30", scenario.helper_token) }

    assert_response :ok
    assert_equal request.id, response.parsed_body.dig("request", "id")
    assert_equal "picked_up", response.parsed_body.dig("request", "state")
    assert_response_matches_contract
  end

  # One waiting poll for each seat and for the helper (LongPoll's key): a
  # waiting call holds a thread of the server's pool, so a caller that
  # opened many would hold them all. The second request is made from the
  # first one's sleep, on a session of its own, and its own sleeps move a
  # clock the two share, so nothing here waits. Returns how often each
  # looked and the second request's session.
  def second_poll_during_first(first_path, first_token, second_path, second_token)
    looks = []
    now = 0.0
    second = nil
    test = self
    original = Leverage::LongPoll.method(:wait)
    Leverage::LongPoll.define_singleton_method(:wait) do |requested, **options, &look|
      index = looks.size
      looks << 0
      sleeper = lambda do |interval|
        if index.zero? && second.nil?
          second = test.open_session
          second.get second_path, headers: { "Authorization" => "Bearer #{second_token}" }
        end
        now += interval
      end
      original.call(requested, **options, clock: -> { now }, sleeper: sleeper) do
        looks[index] += 1
        look.call
      end
    end
    call(first_path, first_token)
    [ looks, second ]
  ensure
    Leverage::LongPoll.define_singleton_method(:wait, original)
  end

  test "a seat's second waiting poll ends its first, which answers none without looking again" do
    token = scenario.token_for(@builder)
    looks, second = second_poll_during_first("/v1/next?wait=30", token, "/v1/next?wait=20", token)

    assert_equal 200, second.response.status
    assert_equal "none", second.response.parsed_body.fetch("kind")
    assert_operator looks[1], :>, 20, "the second poll waits out its own time"
    assert_response :ok
    assert_equal({ "kind" => "none", "id" => nil, "review_id" => nil }, response.parsed_body)
    assert_response_matches_contract
    assert_equal 1, looks[0], "the first poll ends when it wakes"
    refute Leverage::LongPoll.waiting?("seat:#{@builder.id}")
  end

  test "another seat's waiting poll, and a seat's own look that does not wait, leave a waiting poll alone" do
    token = scenario.token_for(@builder)
    other = scenario.token_for(scenario.seat(role: "reviewer"))

    looks, = second_poll_during_first("/v1/next?wait=30", token, "/v1/next?wait=20", other)
    assert_response :ok
    assert_operator looks[0], :>, 20, "the first poll goes on looking until its own time is up"

    looks, second = second_poll_during_first("/v1/next?wait=30", token, "/v1/next?wait=0", token)
    assert_equal 200, second.response.status
    assert_equal [ 1 ], looks.drop(1)
    assert_operator looks[0], :>, 20
  end

  test "the helper's second waiting poll ends its first; a seat's poll does not" do
    token = scenario.helper_token
    looks, second = second_poll_during_first("/v1/helper/next?wait=30", token, "/v1/helper/next?wait=20", token)

    assert_equal 200, second.response.status
    assert_nil second.response.parsed_body.fetch("request")
    assert_response :ok
    assert_equal({ "request" => nil }, response.parsed_body)
    assert_response_matches_contract
    assert_equal 1, looks[0]

    looks, = second_poll_during_first("/v1/helper/next?wait=30", token, "/v1/next?wait=20", scenario.token_for(@builder))
    assert_response :ok
    assert_operator looks[0], :>, 20
  end
end
