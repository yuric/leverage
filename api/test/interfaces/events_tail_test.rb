require "test_helper"

# GET /v1/owner/events (milestone 2 plan MA-20, IF-18): committed events of
# the signed-in owner's workspace with seq greater than after_seq, in seq
# order, at most limit, and next_after_seq; with wait it long-polls until at
# least one exists. A reader that passes next_after_seq back misses nothing
# (test 6 of the PRD is WP10's; this is the read's own behaviour). A
# CommittingTestCase, because a long poll proves nothing inside a test's own
# transaction.
class EventsTailTest < CommittingTestCase
  include ActionDispatch::IntegrationTest::Behavior
  include OpenapiAssertions

  setup do
    @token = scenario.owner_token
    @builder = scenario.seat(role: "builder")
    scenario.task(state: "ready")
    @all = Event.where(workspace_id: scenario.workspace_id).order(:seq).to_a
  end

  def tail(query = "", token: @token)
    get "/v1/owner/events#{"?#{query}" unless query.empty?}", headers: { "Authorization" => "Bearer #{token}" }.compact
  end

  def seqs = response.parsed_body["events"].map { |event| event["seq"] }

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  test "it answers every event of the workspace from the start, in seq order, with next_after_seq" do
    tail
    assert_response :ok
    assert_response_matches_contract
    assert_equal @all.map(&:seq), seqs
    assert_equal @all.map(&:seq).sort, seqs
    assert_equal @all.last.seq, response.parsed_body["next_after_seq"]
  end

  test "after_seq keeps only later events and limit cuts the page, so a reader that passes next_after_seq back misses none" do
    seen = []
    cursor = 0
    pages = 0
    loop do
      tail("after_seq=#{cursor}&limit=2")
      assert_response :ok
      assert_response_matches_contract
      break if seqs.empty?

      assert_operator seqs.size, :<=, 2
      assert_equal seqs.max, response.parsed_body["next_after_seq"]
      seen.concat(seqs)
      cursor = response.parsed_body["next_after_seq"]
      pages += 1
    end
    assert_equal @all.map(&:seq), seen
    assert_operator pages, :>, 1
  end

  test "an empty page answers next_after_seq as the after_seq it was given" do
    last = @all.last.seq
    tail("after_seq=#{last}")
    assert_response :ok
    assert_response_matches_contract
    assert_equal [], response.parsed_body["events"]
    assert_equal last, response.parsed_body["next_after_seq"]
  end

  test "an event carries the contract's fields, its payload as written and no database column besides" do
    tail
    created = response.parsed_body["events"].find { |event| event["type"] == "task.created" }
    expected = Event.find(created["id"])
    assert_equal expected.payload, created["payload"]
    assert_equal scenario.workspace_id, created["workspace_id"]
    assert_equal expected.task_id, created["task_id"]
    assert_equal "owner", created["actor_kind"]
    assert_equal scenario.owner.id, created["actor_id"]
    refute created.key?("xact_id")
    refute created.key?("created_at")
    assert_equal expected.at, Time.iso8601(created["at"]), "times keep their microseconds"
  end

  test "another workspace's events never appear" do
    other = Scenario.new
    other.task(state: "backlog")
    tail
    assert_equal @all.map(&:seq), seqs
    assert_equal [ scenario.workspace_id ], response.parsed_body["events"].map { |event| event["workspace_id"] }.uniq
  end

  test "the default limit is 100 and the largest is 500" do
    105.times { scenario.append("seat.connected", subject: @builder, actor_kind: "owner", actor_id: scenario.owner.id) }
    tail
    assert_equal 100, seqs.size
    tail("limit=500")
    assert_equal @all.size + 105, seqs.size
    tail("limit=1")
    assert_equal [ @all.first.seq ], seqs
  end

  test "wait answers at once when an event already exists, whatever it says" do
    took = elapsed { tail("after_seq=0&wait=10") }
    assert_response :ok
    assert_equal @all.map(&:seq), seqs
    assert_operator took, :<, 3
  end

  test "wait with nothing new waits its seconds and answers an empty page" do
    last = @all.last.seq
    took = elapsed { tail("after_seq=#{last}&wait=1") }
    assert_response :ok
    assert_response_matches_contract
    assert_equal [], response.parsed_body["events"]
    assert_equal last, response.parsed_body["next_after_seq"]
    assert_operator took, :>=, 0.9
    assert_operator took, :<, 4
  end

  test "a long poll holds no database connection while it waits (EN-21)" do
    last = @all.last.seq
    pool = ActiveRecord::Base.connection_pool
    baseline = pool.stat[:busy]
    busy = []
    poller = Thread.new { tail("after_seq=#{last}&wait=2") }
    sleeper = Thread.new do
      3.times do
        busy << pool.stat[:busy]
        Kernel.sleep(0.4)
      end
    end
    [ poller, sleeper ].each(&:join)
    # The test's own connection is the baseline; between its looks the long
    # poll has handed its connection back, so the count drops to it.
    assert_operator busy.min, :<=, baseline, "busy connections while the poll waited: #{busy.inspect}, baseline #{baseline}"
  end

  test "wait ends as soon as an event commits" do
    last = @all.last.seq
    writer = Thread.new do
      Kernel.sleep(0.4)
      scenario.task(state: "backlog")
    end
    took = elapsed { tail("after_seq=#{last}&wait=10") }
    writer.join
    assert_response :ok
    assert_operator seqs.size, :>=, 1
    assert_operator seqs.min, :>, last
    assert_operator took, :<, 5
  end

  test "an after_seq below zero, a limit outside 1 to 500 and a wait outside 0 to 30 are 400 malformed" do
    [ "after_seq=-1", "limit=0", "limit=501", "wait=31", "wait=-1", "wait=soon", "limit=many", "after_seq=1.5" ].each do |query|
      tail(query)
      assert_response :bad_request, query
      assert_equal "malformed", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  test "it is 401 without an owner token" do
    tail("", token: nil)
    assert_response :unauthorized
    tail("", token: scenario.token_for(@builder))
    assert_response :unauthorized
  end
end
