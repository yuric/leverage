require "test_helper"

# GET /v1/next (milestone 2 plan WP8, PRD L514-L529, IF-7, IF-34, EN-13,
# EN-20): which item a seat is told about, the first true row of the
# precedence table, read from the rows Scenario builds. The kinds `command`,
# `answer`, `action` and `job` cannot be true in this milestone and are
# never answered (plan §1.2). Whether a task or a review is waiting for the
# seat is Eligibility's (WP3) and what the briefing's hash is, Briefing's:
# both are scripted here, each by its own two-method double.
class NextItemTest < ActiveSupport::TestCase
  include OpenapiAssertions

  Item = Struct.new(:kind, :id, :review_id) do
    def self.none = new("none", nil, nil)
    def to_h = { "kind" => kind, "id" => id, "review_id" => review_id }
  end

  # What Eligibility answers: the task or the review waiting for the seat.
  class Waiting
    def initialize(task: nil, review: nil)
      @task = task
      @review = review
    end

    def next_task(_seat) = @task
    def next_review(_seat) = @review
  end

  # What Briefing answers: the hash of the briefing a seat would read now.
  class Hashing
    def initialize(hash = "made-up-hash") = @hash = hash
    def hash_for(_subject, _seat) = @hash
  end

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @reviewer = @scenario.seat(role: "reviewer")
  end

  def item(seat, eligibility: Waiting.new, briefing: Hashing.new)
    Leverage::Reads::NextItem.with_collaborators(eligibility: eligibility, briefing: briefing) do
      Leverage::Reads::NextItem.call(seat.reload)
    end
  end

  def assert_item(expected, actual)
    assert_equal expected.to_h, actual
  end

  # A task the builder holds after a failed review gave it a fresh lease
  # (review.failed names the builder in lease_seat_id); returns the task.
  def reworked(builder: @builder, reviewer: @reviewer)
    task = @scenario.task(state: "in_review", builder: builder)
    review = @scenario.review(task, reviewer: reviewer)
    ActiveRecord::Base.transaction do
      review.update!(verdict: "failed", notes: "Made-up notes.", lease_due_at: nil)
      task.update!(state: "working", holder_seat_id: builder.id, round: task.round + 1,
        lease_due_at: @scenario.database_now + 600)
      @scenario.append("review.failed", task: task, subject: review, actor_kind: "seat", actor_id: reviewer.id,
        payload: { failed_criterion_ids: [], failed_rule_check_id: nil, lease_seat_id: builder.id, wait_cause: nil })
    end
    task.reload
  end

  def lease_event(task, type) = Event.where(task_id: task.id, type: type).order(:seq).last

  def acknowledge(seat, task, event, hash: "made-up-hash", review: nil)
    BriefingAcknowledgement.create!(workspace_id: task.workspace_id, seat_id: seat.id, task_id: task.id, review_id: review&.id,
      lease_event_id: event.id, briefing_hash: hash, acknowledged_at: @scenario.database_now)
  end

  def open_hold(task, reason: "rounds_exceeded")
    Hold.create!(workspace_id: task.workspace_id, task_id: task.id, reason: reason, opened_at: @scenario.database_now,
      opened_by_kind: "app")
  end

  # none, task and review

  test "a builder with nothing waiting is told none" do
    assert_item Item.none, item(@builder)
  end

  test "a builder with a task waiting is told task, with no id" do
    task = @scenario.task(state: "ready")

    assert_item Item.new("task", nil, nil), item(@builder, eligibility: Waiting.new(task: task))
  end

  test "a reviewer with a review waiting is told review, with no id" do
    task = @scenario.task(state: "in_review")
    review = Review.where(task_id: task.id).sole

    assert_item Item.new("review", nil, nil), item(@reviewer, eligibility: Waiting.new(review: review))
  end

  test "a builder is never told review and a reviewer is never told task" do
    task = @scenario.task(state: "ready")
    review = Review.new

    assert_item Item.none, item(@reviewer, eligibility: Waiting.new(task: task))
    assert_item Item.none, item(@builder, eligibility: Waiting.new(review: review))
  end

  test "a seat that holds a task or a review is not asked what is waiting for it" do
    held = @scenario.task(state: "working", builder: @builder)
    task = @scenario.task(state: "ready")
    in_review = @scenario.task(state: "in_review")
    @scenario.review(in_review, reviewer: @reviewer)
    waiting = Waiting.new(task: task, review: Review.where(task_id: in_review.id).sole)

    assert_item Item.none, item(@builder, eligibility: waiting)
    assert_item Item.none, item(@reviewer, eligibility: waiting)
    assert_equal @builder.id, Task.find(held.id).holder_seat_id
  end

  test "a seat whose lease is past its due time is treated as holding nothing, and nothing is written" do
    task = @scenario.task(state: "working", builder: @builder)
    @scenario.make_due(task)
    ready = @scenario.task(state: "ready")
    before = [ Event.count, task.reload.lease_due_at, task.holder_seat_id ]

    assert_item Item.new("task", nil, nil), item(@builder, eligibility: Waiting.new(task: ready))
    assert_equal before, [ Event.count, task.reload.lease_due_at, task.holder_seat_id ]
  end

  # rework

  test "a builder given a fresh lease by a failed review is told rework, with the task, until it acknowledges" do
    task = reworked

    assert_item Item.new("rework", task.id, nil), item(@builder)
    assert_item Item.new("rework", task.id, nil), item(@builder)

    acknowledge(@builder, task, lease_event(task, "review.failed"))

    assert_item Item.none, item(@builder)
  end

  test "an acknowledgement under an earlier lease does not clear rework" do
    task = reworked
    acknowledge(@builder, task, lease_event(task, "task.claimed"))

    assert_item Item.new("rework", task.id, nil), item(@builder)
  end

  test "a builder on its first lease, which task.claimed gave it, is told none whether it has acknowledged or not" do
    task = @scenario.task(state: "working", builder: @builder)

    assert_item Item.none, item(@builder)

    acknowledge(@builder, task, lease_event(task, "task.claimed"))

    assert_item Item.none, item(@builder)
  end

  test "a seat that is not the holder of the reworked task is not told rework" do
    task = reworked
    other = @scenario.seat(role: "builder")

    assert_item Item.none, item(other)
    assert_equal @builder.id, task.holder_seat_id
  end

  test "rework is not told while a hold on the task is open" do
    task = reworked
    open_hold(task)

    assert_item Item.none, item(@builder)
  end

  # resume

  test "a builder whose task's hold has closed is told resume until the flag is cleared" do
    task = @scenario.task(state: "working", builder: @builder)
    task.update_columns(resume_pending_since: @scenario.database_now)

    assert_item Item.new("resume", task.id, nil), item(@builder)

    task.update_columns(resume_pending_since: nil)

    assert_item Item.none, item(@builder)
  end

  test "resume comes before rework" do
    task = reworked
    task.update_columns(resume_pending_since: @scenario.database_now)

    assert_item Item.new("resume", task.id, nil), item(@builder)
  end

  test "resume is not told while a hold is open on the task: none" do
    task = @scenario.task(state: "working", builder: @builder)
    task.update_columns(resume_pending_since: @scenario.database_now)
    open_hold(task)

    assert_item Item.none, item(@builder)
  end

  test "a hold that has closed no longer keeps the answer at none" do
    task = reworked
    hold = open_hold(task)
    assert_item Item.none, item(@builder)

    hold.update_columns(closed_at: @scenario.database_now)

    assert_item Item.new("rework", task.id, nil), item(@builder)
  end

  # briefing_changed

  test "a builder whose acknowledged hash is no longer the briefing's is told briefing_changed with the task" do
    task = @scenario.task(state: "working", builder: @builder)
    acknowledge(@builder, task, lease_event(task, "task.claimed"), hash: "old-hash")

    assert_item Item.new("briefing_changed", task.id, nil), item(@builder, briefing: Hashing.new("new-hash"))
    assert_item Item.none, item(@builder, briefing: Hashing.new("old-hash"))
  end

  test "the latest acknowledgement under the lease is the one compared" do
    task = @scenario.task(state: "working", builder: @builder)
    event = lease_event(task, "task.claimed")
    acknowledge(@builder, task, event, hash: "old-hash").update_columns(acknowledged_at: @scenario.database_now - 60)
    acknowledge(@builder, task, event, hash: "new-hash")

    assert_item Item.none, item(@builder, briefing: Hashing.new("new-hash"))
  end

  test "a seat that has not acknowledged is not told briefing_changed" do
    @scenario.task(state: "working", builder: @builder)

    assert_item Item.none, item(@builder, briefing: Hashing.new("any-hash"))
  end

  test "a reviewer whose review's briefing changed is told briefing_changed with the task and the review" do
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: @reviewer)
    acknowledge(@reviewer, task, lease_event(task, "review.started"), hash: "old-hash", review: review)

    assert_item Item.new("briefing_changed", task.id, review.id), item(@reviewer, briefing: Hashing.new("new-hash"))
    assert_item Item.none, item(@reviewer, briefing: Hashing.new("old-hash"))
  end

  test "briefing_changed comes before resume, rework and task" do
    task = reworked
    task.update_columns(resume_pending_since: @scenario.database_now)
    acknowledge(@builder, task, lease_event(task, "review.failed"), hash: "old-hash")

    assert_item Item.new("briefing_changed", task.id, nil), item(@builder, briefing: Hashing.new("new-hash"))
  end

  # the kinds this milestone cannot make true

  test "the kinds of later milestones are never answered" do
    task = reworked
    task.update_columns(resume_pending_since: @scenario.database_now)
    @scenario.task(state: "ready")
    Command.create!(workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: @builder.id, key: "key-unread",
      command: "heartbeat", request_hash: "made-up-hash", outcome: "completed", result: {}, notify: true)

    assert_not_includes %w[command answer action job], item(@builder).fetch("kind")
  end

  test "the answer is a NextItem of the contract" do
    task = reworked

    [ item(@builder), item(@reviewer), Item.none.to_h ].each { |body| assert_matches_component("NextItem", body) }
    assert_equal task.id, item(@builder).fetch("id")
  end

  # the real Eligibility and Briefing

  test "with the real Eligibility and Briefing a builder is told task for a Ready task, and a reviewer none" do
    credential = @scenario.credential
    seat = @scenario.seat(role: "builder", credential: credential)
    @scenario.task(state: "ready")

    assert_item Item.new("task", nil, nil), Leverage::Reads::NextItem.call(seat)
    assert_item Item.none, Leverage::Reads::NextItem.call(@scenario.seat(role: "reviewer", credential: credential))
  end
end

# The write behind a poll (milestone 2 plan EN-20, IN-10): a seat's last
# polled time at most every 10 seconds, the helper's last report every 15, an
# owner session's last use every 5 minutes. Each takes the workspace lock,
# and only when it writes.
class RecordPollTest < ActiveSupport::TestCase
  def record_poll = Leverage::Transitions::RecordPoll

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(role: "builder")
    @helper = @scenario.helper
    @session = @scenario.owner_session
  end

  def ago(seconds) = @scenario.database_now - seconds

  test "a seat's last polled time is written the first time and not again within 10 seconds" do
    assert_nil @seat.reload.last_polled_at
    assert record_poll.seat(@seat)
    first = @seat.reload.last_polled_at
    assert_in_delta @scenario.database_now.to_f, first.to_f, 5

    @seat.update_columns(last_polled_at: ago(9))
    stale = @seat.reload.last_polled_at

    assert_not record_poll.seat(@seat)
    assert_equal stale, @seat.reload.last_polled_at

    @seat.update_columns(last_polled_at: ago(11))

    assert record_poll.seat(@seat)
    assert_operator @seat.reload.last_polled_at, :>, ago(5)
  end

  test "a helper's last report is written at most every 15 seconds" do
    assert record_poll.helper(@helper)
    @helper.update_columns(last_reported_at: ago(14))

    assert_not record_poll.helper(@helper)

    @helper.update_columns(last_reported_at: ago(16))

    assert record_poll.helper(@helper)
    assert_operator @helper.reload.last_reported_at, :>, ago(5)
  end

  test "a session's last use is written at most every 5 minutes" do
    assert record_poll.session(@session)
    @session.update_columns(last_used_at: ago(299))

    assert_not record_poll.session(@session)

    @session.update_columns(last_used_at: ago(301))

    assert record_poll.session(@session)
    assert_operator @session.reload.last_used_at, :>, ago(5)
  end

  # The SQL a block sends, in order.
  def statements(&block)
    sent = []
    callback = ->(*, payload) { sent << payload.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    sent
  end

  test "a write takes the workspace lock first and writes no event" do
    events = Event.where(workspace_id: @scenario.workspace_id).count

    sent = statements { record_poll.seat(@seat) }

    lock = sent.index { |sql| sql.match?(/FROM "workspaces".*FOR UPDATE/m) }
    write = sent.index { |sql| sql.match?(/UPDATE "seats"/) }
    assert_not_nil lock
    assert_not_nil write
    assert_operator lock, :<, write
    assert_equal events, Event.where(workspace_id: @scenario.workspace_id).count
  end

  test "a poll that is not due takes no lock and writes nothing" do
    @seat.update_columns(last_polled_at: ago(1))

    sent = statements { record_poll.seat(@seat) }

    assert_not(sent.any? { |sql| sql.match?(/FOR UPDATE|UPDATE "seats"/) })
  end

  test "a poll only touches its own row" do
    other = @scenario.seat(role: "reviewer")

    record_poll.seat(@seat)

    assert_nil other.reload.last_polled_at
  end

  test "a poll on a row that is gone writes nothing and does not raise" do
    @seat.delete

    assert_not record_poll.seat(@seat)
  end
end

# The write behind a read (milestone 2 plan IN-10, DB-34, EN-20).
class MarkReadTest < ActiveSupport::TestCase
  def mark_read = Leverage::Transitions::MarkRead

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(role: "builder")
  end

  def command(**columns)
    Command.create!(workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: @seat.id, key: "key-#{SecureRandom.hex(4)}",
      command: "heartbeat", request_hash: "made-up-hash", outcome: "completed", result: {}, **columns)
  end

  test "command sets read_at to the database clock once and leaves everything else" do
    row = command
    before = row.reload.attributes.except("read_at", "updated_at")

    assert mark_read.command(row)

    assert_not_nil row.reload.read_at
    assert_in_delta @scenario.database_now.to_f, row.read_at.to_f, 5
    assert_equal before, row.attributes.except("read_at", "updated_at")
    first = row.read_at

    assert_not mark_read.command(row)
    assert_equal first, row.reload.read_at
  end

  test "command writes no event" do
    row = command
    events = Event.count

    mark_read.command(row)

    assert_equal events, Event.count
  end

  test "helper_request marks a queued request picked up with the database clock and no event" do
    request = HelperRequest.create!(workspace_id: @scenario.workspace_id, kind: "verify", state: "queued",
      requested_at: @scenario.database_now)
    events = Event.count

    picked = mark_read.helper_request(request)

    assert_equal request.id, picked.id
    assert_equal "picked_up", picked.state
    assert_equal "picked_up", request.reload.state
    assert_in_delta @scenario.database_now.to_f, request.picked_up_at.to_f, 5
    assert_equal events, Event.count
  end

  test "helper_request does not pick a request up twice" do
    request = HelperRequest.create!(workspace_id: @scenario.workspace_id, kind: "verify", state: "picked_up",
      requested_at: @scenario.database_now, picked_up_at: @scenario.database_now - 60)
    before = request.reload.picked_up_at

    assert_nil mark_read.helper_request(request)
    assert_equal before, request.reload.picked_up_at
  end
end

# GET /v1/next over HTTP (milestone 2 plan WP8, IN-13, EN-20).
class NextHttpTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @token = @scenario.token_for(@builder)
  end

  def get_next(query = "wait=0", token: @token)
    headers = {}
    headers["Authorization"] = "Bearer #{token}" if token
    Leverage::Reads::NextItem.with_collaborators(eligibility: NextItemTest::Waiting.new, briefing: NextItemTest::Hashing.new) do
      get "/v1/next?#{query}", headers: headers
    end
  end

  test "answers a NextItem of the contract and writes the seat's last polled time" do
    task = @scenario.task(state: "working", builder: @builder)
    task.update_columns(resume_pending_since: @scenario.database_now)

    get_next

    assert_response :ok
    assert_equal({ "kind" => "resume", "id" => task.id, "review_id" => nil }, response.parsed_body)
    assert_response_matches_contract
    assert_not_nil @builder.reload.last_polled_at
  end

  test "answers none with null ids when nothing is true" do
    get_next

    assert_equal({ "kind" => "none", "id" => nil, "review_id" => nil }, response.parsed_body)
    assert_response_matches_contract
  end

  test "writes no event and no commands row" do
    before = [ Event.count, Command.count ]

    get_next

    assert_equal before, [ Event.count, Command.count ]
  end

  test "a wait that is not a whole number of seconds from 0 to 30 is 400 malformed" do
    [ "wait=31", "wait=-1", "wait=abc", "wait=1.5", "wait=", "wait=0x1" ].each do |query|
      get_next query

      assert_response :bad_request, query
      assert_equal "malformed", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  test "a missing wait means 30 seconds and a seat with an item is answered at once" do
    task = @scenario.task(state: "working", builder: @builder)
    task.update_columns(resume_pending_since: @scenario.database_now)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    get_next ""

    assert_response :ok
    assert_equal "resume", response.parsed_body["kind"]
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  test "is 401 for no token, an owner's token, a helper's token, a removed seat and an ended token" do
    removed = @scenario.seat(role: "builder")
    @scenario.remove(removed)
    ended = @scenario.seat(role: "builder")
    token = @scenario.token_for(ended)
    @scenario.end_token(ended)
    [ nil, @scenario.owner_token, @scenario.helper_token, @scenario.token_for(removed), token ].each do |candidate|
      get_next token: candidate

      assert_response :unauthorized
      assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
    assert_nil removed.reload.last_polled_at
  end
end
