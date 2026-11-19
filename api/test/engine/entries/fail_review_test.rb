require "test_helper"

# Review fails (PRD Lifecycle L91, Rework and escalation L127-L131;
# milestone 2 plan EN-9, EN-12, EN-13, EN-28): at review.failed, the named
# criteria reopen and the round goes up. A free previous builder gets a
# fresh lease and the task goes back to Working; otherwise the task goes to
# Ready. No rule escalates in this milestone. A failure that brings the
# round to the limit also holds the task with rounds_exceeded and opens the
# Past the round limit item.
class FailReviewTest < ActiveSupport::TestCase
  T = Leverage::Transitions
  B = Leverage::Briefing

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @builder = @scenario.seat(role: "builder")
    @reviewer = @scenario.seat(role: "reviewer")
    @task = @scenario.task(state: "in_review", builder: @builder, criteria: %w[build build review])
    @copy, @layout = Criterion.where(task_id: @task.id, kind: "build").order(:position).to_a
    @review = @scenario.review(@task, reviewer: @reviewer)
  end

  def apply(command, params, seat = @reviewer)
    key = "key-#{SecureRandom.hex(6)}"
    @key = key
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params))
  end

  def written = Event.where(workspace_id: @scenario.workspace_id, command_id: @key).order(:seq).to_a

  def acknowledge(review = @review)
    apply("acknowledge_review_briefing", "id" => review.id,
      "briefing_hash" => B.hash_for(@task, seat: @reviewer, review: review))
  end

  def fail_with(failed, review: @review)
    apply("fail_review", "id" => review.id, "verdict" => "failed", "failed_criteria" => failed,
      "notes" => "The second criterion does not hold yet.", "tokens" => 1200, "spend" => 0.42)
  end

  test "with the builder free: Working, round 1, a fresh lease, the named criterion reopened" do
    acknowledge
    assert fail_with([ @layout.id ]).completed?

    @task.reload
    assert_equal [ "working", 1, @builder.id, @builder.id ],
      @task.attributes.values_at("state", "round", "holder_seat_id", "builder_seat_id")
    failed, reopened, cost = written
    assert_in_delta failed.at + 600, @task.lease_due_at, 0.001
    assert_equal BigDecimal("0.42"), @task.spent
    assert_equal [ "passed", "open" ], [ @copy.reload.state, @layout.reload.state ]
    assert_equal [ nil, nil ], @layout.attributes.values_at("passed_at", "passed_by_seat_id")
    assert_equal "open", Criterion.find_by!(task_id: @task.id, kind: "review").state
    @review.reload
    assert_equal [ "failed", [ @layout.id ], "The second criterion does not hold yet.", nil ],
      @review.attributes.values_at("verdict", "failed_criteria", "notes", "lease_due_at")

    assert_equal %w[review.failed criterion.reopened cost.reported], written.map(&:type)
    assert_equal({ "failed_criterion_ids" => [ @layout.id ], "failed_rule_check_id" => nil,
                   "lease_seat_id" => @builder.id, "wait_cause" => nil }, failed.payload)
    assert_equal [ "review", @review.id ], [ failed.subject_kind, failed.subject_id ]
    assert_equal [ "criterion", @layout.id ], [ reopened.subject_kind, reopened.subject_id ]
    assert_equal [ "review", @review.id, { "tokens" => 1200, "spend" => 0.42 } ],
      [ cost.subject_kind, cost.subject_id, cost.payload ]
    assert(written.all? { |event| event.round.zero? && event.actor_id == @reviewer.id }, "EN-28: the failed round")
    assert_equal :missing, B.acknowledgement(@task, seat: @builder)
  end

  test "with the builder busy: Ready, no holder, no builder, no lease" do
    acknowledge
    @scenario.task(state: "working", builder: @builder)
    assert fail_with([ @copy.id, @layout.id ]).completed?

    @task.reload
    assert_equal [ "ready", 1, nil, nil, nil ],
      @task.attributes.values_at("state", "round", "holder_seat_id", "builder_seat_id", "lease_due_at")
    assert_equal %w[review.failed criterion.reopened criterion.reopened cost.reported], written.map(&:type)
    assert_nil written.first.payload["lease_seat_id"]
    assert_equal [ @copy.id, @layout.id ], written[1, 2].map(&:subject_id)
  end

  test "a paused previous builder is busy" do
    acknowledge
    @builder.update!(paused: true)
    assert fail_with([ @copy.id ]).completed?
    assert_equal "ready", @task.reload.state
  end

  test "at the round limit the task is held with rounds_exceeded and the Past the round limit item opens" do
    @task.update_columns(round: 2)
    @review.update_columns(round: 2)
    acknowledge
    assert fail_with([ @copy.id ]).completed?

    types = written.map(&:type)
    assert_equal %w[review.failed criterion.reopened cost.reported hold.opened inbox.opened], types
    failed = written.first
    opened, inbox = written.last(2)
    assert_equal [ "app", nil, failed.id, 2, { "reason" => "rounds_exceeded", "rule_id" => nil, "credential_id" => nil } ],
      [ opened.actor_kind, opened.actor_id, opened.cause_id, opened.round, opened.payload ]
    assert_equal [ opened.id, { "kind" => "past_round_limit" } ], [ inbox.cause_id, inbox.payload ]
    hold = Hold.find_by!(task_id: @task.id, reason: "rounds_exceeded", closed_at: nil)
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_equal [ "past_round_limit", { "round" => 3 } ], [ item.kind, item.facts ]
    assert_equal [ "working", 3 ], @task.reload.attributes.values_at("state", "round")
  end

  test "one more round moves the limit" do
    @task.update_columns(round: 2, extra_rounds: 1)
    @review.update_columns(round: 2)
    acknowledge
    assert fail_with([ @copy.id ]).completed?
    assert_not_includes written.map(&:type), "hold.opened"
  end

  test "no named criterion, the review criterion, or another task's criterion is 422 invalid" do
    acknowledge
    review_criterion = Criterion.find_by!(task_id: @task.id, kind: "review")
    other = Criterion.where(task_id: @scenario.task(state: "ready").id).first
    [ [], [ review_criterion.id ], [ other.id ], [ SecureRandom.uuid ] ].each do |failed|
      assert_raises(T::Invalid, failed.inspect) { fail_with(failed) }
    end
    assert_equal "in_review", @task.reload.state
  end

  test "before the reviewer's briefing is acknowledged it is briefing_not_acknowledged" do
    assert_equal "briefing_not_acknowledged", fail_with([ @copy.id ]).refusal.code
  end

  # A lease ends at its due time (L120, EN-14): a builder whose only other
  # lease is past it holds nothing, whether or not the sweep has run. The
  # lease's timer is written first, at its due time, so the log says why.
  test "a builder whose other lease is past its due time is free: that lease ends first, then the task is its again" do
    acknowledge
    other = @scenario.make_due(@scenario.task(state: "working", builder: @builder))
    before = @scenario.workspace.reload.last_seq
    assert fail_with([ @layout.id ]).completed?

    assert_equal [ "working", @builder.id ], @task.reload.attributes.values_at("state", "holder_seat_id")
    assert_equal [ "ready", nil ], other.reload.attributes.values_at("state", "holder_seat_id")
    types = Event.where(workspace_id: @scenario.workspace_id).where("seq > ?", before).order(:seq).map(&:type)
    assert_equal %w[task.lease_expired review.failed criterion.reopened cost.reported], types
    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
  end

end
