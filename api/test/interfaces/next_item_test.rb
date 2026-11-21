require "test_helper"

# GET /v1/next returns the first true row of the PRD's precedence table.
# The tests build persisted rows with Scenario and script the answers from
# Eligibility, Briefing and Jobs with their own doubles.
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

  # What Jobs answers (milestone 4, WP6): the job claim-next would give the
  # seat, with the seats it was asked about.
  class Claimable
    attr_reader :asked

    def initialize(job = nil)
      @job = job
      @asked = []
    end

    def next_for(seat)
      @asked << seat.id
      @job
    end
  end

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder")
    @reviewer = @scenario.seat(role: "reviewer")
  end

  def item(seat, eligibility: Waiting.new, briefing: Hashing.new, jobs: Claimable.new)
    Leverage::Reads::NextItem.with_collaborators(eligibility: eligibility, briefing: briefing, jobs: jobs) do
      Leverage::Reads::NextItem.call(seat.reload)
    end
  end

  # A commands row of the seat whose outcome it has not read: notify is set
  # once a transition that waited ends (milestone 4 plan RE-3, DB-34).
  def unread(seat, outcome: "completed", notify: true, **columns)
    refusal = { code: "invalid_state", rule_id: nil, reason: nil } if outcome == "refused"
    Command.create!({ workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
                      key: "key-#{SecureRandom.hex(6)}", command: "submit", request_hash: "made-up-hash", outcome: outcome,
                      result: ({} if outcome == "completed"), refusal: refusal, notify: notify }.merge(columns))
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

  # command (milestone 4 plan RE-3; PRD L381, L522; DB-34)

  test "a seat whose command is no longer pending is told command with its key, until it reads the outcome" do
    row = unread(@builder)

    assert_item Item.new("command", row.key, nil), item(@builder)

    Leverage::Transitions::MarkRead.command(row)
    assert_item Item.none, item(@builder)
  end

  test "a refused command is told as a completed one is, the oldest unread first" do
    later = unread(@builder)
    earlier = unread(@builder, outcome: "refused")
    later.update_columns(updated_at: earlier.updated_at + 1)

    assert_equal earlier.key, item(@builder).fetch("id")
  end

  test "command comes before every other kind, a hold on the seat's task included" do
    task = reworked
    task.update_columns(resume_pending_since: @scenario.database_now)
    acknowledge(@builder, task, lease_event(task, "review.failed"), hash: "old-hash")
    open_hold(task)
    row = unread(@builder)

    assert_item Item.new("command", row.key, nil), item(@builder, eligibility: Waiting.new(task: task))
  end

  test "a command still pending, one already read, one not marked notify, and another seat's are not told" do
    unread(@builder, outcome: "pending", result: nil)
    unread(@builder, read_at: @scenario.database_now)
    unread(@builder, notify: false)
    unread(@reviewer)

    assert_item Item.none, item(@builder)
  end

  # job (milestone 4 plan RD-35 to RD-40; PRD L527)

  test "an orchestrator and a planner are told job while claim-next has one for them, and none otherwise" do
    task = @scenario.task(state: "backlog")
    [ @scenario.orchestrator, @scenario.planner ].each do |seat|
      job = @scenario.job(kind: "contract_draft", task: task)
      jobs = Claimable.new(job)

      assert_item Item.new("job", nil, nil), item(seat, jobs: jobs)
      assert_equal [ seat.id ], jobs.asked
      assert_item Item.none, item(seat, jobs: Claimable.new)
    end
  end

  test "a builder and a reviewer are never asked for a job, and a job seat never for a task or a review" do
    jobs = Claimable.new(@scenario.job(kind: "contract_draft", task: @scenario.task(state: "backlog")))
    waiting = Waiting.new(task: @scenario.task(state: "ready"), review: Review.new)

    assert_equal "task", item(@builder, eligibility: waiting, jobs: jobs).fetch("kind")
    assert_equal "review", item(@reviewer, eligibility: waiting, jobs: jobs).fetch("kind")
    assert_empty jobs.asked
    assert_equal "job", item(@scenario.orchestrator, eligibility: waiting, jobs: jobs).fetch("kind")
  end

  test "command comes before job" do
    orchestrator = @scenario.orchestrator
    row = unread(orchestrator, command: "submit_job_result")

    assert_item Item.new("command", row.key, nil),
      item(orchestrator, jobs: Claimable.new(@scenario.job(kind: "contract_draft", task: @scenario.task(state: "backlog"))))
  end

  # answers and outward actions (WP11)

  test "answered and overturned questions repeat until the asking holder reads them" do
    task = @scenario.task(state: "working", builder: @builder)
    %w[answered overturned].each do |outcome|
      question = @scenario.question(task, outcome: outcome, blocking: false)
      expected = Item.new("answer", question.id, nil)

      assert_item expected, item(@builder)
      assert_item expected, item(@builder)
      assert_nil question.reload.read_at

      question.update_columns(read_at: @scenario.database_now)
      assert_item Item.none, item(@builder)
    end
  end

  test "open questions and questions asked by another seat or on a task the builder no longer holds are silent" do
    submitted = @scenario.task(state: "in_review", builder: @builder)
    held = @scenario.task(state: "working", builder: @builder)
    @scenario.question(held, outcome: "open", blocking: false)
    @scenario.question(held, outcome: "passed_on", blocking: false)
    @scenario.question(held, outcome: "answered", blocking: false, asking_seat: @scenario.seat(role: "builder"))
    @scenario.question(submitted, outcome: "answered", blocking: false)

    assert_item Item.none, item(@builder)
  end

  test "an answer comes after resume and before an action under a fresh lease" do
    task = @scenario.finishing_task(builder: @builder, actions: [ { kind: "publish", description: "Publish the sample.", state: "approved" } ])
    question = @scenario.question(task, outcome: "answered", blocking: false)
    task.update_columns(resume_pending_since: @scenario.database_now)

    assert_item Item.new("resume", task.id, nil), item(@builder)

    task.update_columns(resume_pending_since: nil)
    assert_item Item.new("answer", question.id, nil), item(@builder)

    question.update_columns(read_at: @scenario.database_now)
    assert_item Item.new("action", task.id, nil), item(@builder)
  end

  test "an approved action under a live lease repeats until the builder acknowledges that lease" do
    task = @scenario.finishing_task(builder: @builder, actions: [ { kind: "publish", description: "Publish the sample.", state: "approved" } ])
    waiting = Waiting.new(task: @scenario.task(state: "ready"))
    acknowledge(@builder, task, lease_event(task, "task.claimed"))

    assert_item Item.new("action", task.id, nil), item(@builder, eligibility: waiting)
    assert_item Item.new("action", task.id, nil), item(@builder, eligibility: waiting)

    acknowledge(@builder, task, lease_event(task, "action.approved"))
    assert_item Item.none, item(@builder, eligibility: waiting)
  end

  test "an approved action with no holder or an expired lease is silent" do
    actions = [ { kind: "publish", description: "Publish the sample.", state: "approved" } ]
    @scenario.finishing_task(builder: @builder, holder: false, actions: actions)
    assert_item Item.none, item(@builder)

    task = @scenario.finishing_task(builder: @builder, actions: actions)
    @scenario.make_due(task)
    assert_item Item.none, item(@builder)
  end

  test "owner rework gives a rework notice until the fresh lease is acknowledged" do
    task = @scenario.finishing_task(builder: @builder, actions: [ { kind: "publish", description: "Publish the sample.", state: "approved" } ])
    acknowledge(@builder, task, lease_event(task, "action.approved"))
    ActiveRecord::Base.transaction do
      task.update!(state: "working", round: task.round + 1, lease_due_at: @scenario.database_now + 600)
      ctx = @scenario.context
      begin
        ctx.emit("task.returned_for_rework", task: task, actor_kind: "owner", actor_id: @scenario.owner.id,
          payload: { lease_seat_id: @builder.id, wait_cause: nil }, command_id: nil)
      rescue Leverage::Steps::Unsupported
        # The event is written before Steps, whose new rows are built separately.
      end
    end

    assert_item Item.new("rework", task.id, nil), item(@builder)
    acknowledge(@builder, task, lease_event(task, "task.returned_for_rework"))
    assert_item Item.none, item(@builder)
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

# GET /v1/next with the real Eligibility (milestone 3 plan HD-4): it offers
# a task or a review only when a claim would take it, so it never offers
# what a claim refuses. A seat the app runs is offered work only while its
# run is on its first available candidate.
class NextItemEligibilityTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @own = @scenario.credential(provider: "claude")
    @below = @scenario.credential(provider: "codex")
    @builder = @scenario.seat(role: "builder", credential: @own)
    @reviewer = @scenario.seat(role: "reviewer", credential: @own)
  end

  def claim(seat, command)
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: seat.id,
      key: "key-#{SecureRandom.hex(6)}", request_hash: command, params: {}))
  end

  def offered(seat) = Leverage::Reads::NextItem.call(seat.reload)["kind"]

  # The kind offered and whether a claim of it completes agree, for each
  # place the seat's run can be.
  def assert_agree(seat, kind, command)
    [ @own, @below, nil ].each do |where|
      @scenario.run(seat, on: where)
      expected = offered(seat)
      outcome = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        outcome = claim(seat, command)
        raise ActiveRecord::Rollback
      end
      assert_equal expected == kind, outcome.completed?, "run on #{where&.provider.inspect}: offered #{expected}"
    end
  end

  test "a builder is offered a task exactly when its claim would take it" do
    @scenario.task(state: "ready")
    assert_agree(@builder, "task", "claim")

    @scenario.limit_credential(@own, reset_at: @scenario.database_now + 3600)
    assert_agree(@builder, "task", "claim")
    @scenario.run(@builder, on: @below)
    assert_equal "task", offered(@builder)
  end

  # L526, milestone 4 plan RD-12: review is told only while review
  # claim-next has a review for the seat, so never for a review the claim
  # filter leaves out for it. The filter here is a Gating::StandIn world's
  # in which the provider rule keeps the task from Claude reviewers; claim-
  # next's choice is Eligibility.next_review, which the claim takes.
  test "a reviewer is never told review for a review the claim filter leaves out for it, and is for one it does not" do
    task = @scenario.task(state: "in_review")
    review = Review.find_by!(task_id: task.id, verdict: nil)
    other = @scenario.seat(role: "reviewer", credential: @below)
    Leverage::Gating.implementation = Leverage::Gating::StandIn.new(
      rules: [ { id: SecureRandom.uuid, version_id: SecureRandom.uuid, version: 1, hook: "review.assign", kind: "policy",
                 checker: "app", on_fail: nil, route: nil, enabled: true, scope: "covers" } ],
      built_by: { task.id => [ "claude" ] }, reviews: { review.id => task.id },
      seat_providers: { @reviewer.id => "claude", other.id => "codex" })

    assert_nil Leverage::Eligibility.next_review(@reviewer.reload), "claim-next has no review for it"
    assert_equal "none", offered(@reviewer)
    assert_equal review, Leverage::Eligibility.next_review(other.reload)
    assert_equal "review", offered(other)
  end

  test "a reviewer is offered a review exactly when its claim would take it" do
    @scenario.task(state: "in_review")
    assert_agree(@reviewer, "review", "claim_review")

    @scenario.sign_out_credential(@own)
    assert_agree(@reviewer, "review", "claim_review")
    @scenario.run(@reviewer, on: @below)
    assert_equal "review", offered(@reviewer)
  end
end
