require "test_helper"
require_relative "../gate_support"

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

  # HE-14, HD-1 (milestone 3 plan §2.1): a builder the app runs is free for
  # the fresh lease only if one of its candidates is available for the task;
  # the lease starts on the first of them, with credential.switched when it
  # is not the credential last recorded for the task (caused by
  # review.failed, written by the app after the row's own events), and the
  # seat's run is placed there.

  # A task In review built by builder, its review claimed and acknowledged
  # by a reviewer of its own (a reviewer holds one review at a time).
  def in_review_built_by(builder)
    @other_reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review", builder: builder, criteria: %w[build review])
    review = @scenario.review(task, reviewer: @other_reviewer)
    apply("acknowledge_review_briefing", { "id" => review.id,
      "briefing_hash" => B.hash_for(task, seat: @other_reviewer, review: review) }, @other_reviewer)
    [ task, review, Criterion.find_by!(task_id: task.id, kind: "build") ]
  end

  def fail_built(review, criterion)
    apply("fail_review", { "id" => review.id, "verdict" => "failed", "failed_criteria" => [ criterion.id ],
      "notes" => "The named criterion does not hold yet.", "tokens" => 1, "spend" => 0 }, @other_reviewer)
  end

  test "the fresh lease starts on the builder's first available login, with credential.switched (trace 14)" do
    claude_o = @scenario.credential(provider: "claude", model: "claude-model-1")
    claude_m = @scenario.credential(provider: "claude", model: "claude-model-1")
    builder = @scenario.seat(role: "builder", credential: claude_o, model: "claude-model-1")
    task, review, criterion = in_review_built_by(builder)
    task.update_columns(credential_id: claude_m.id)

    ensured = nil
    calls = []
    original = Leverage::SeatRuns.method(:ensure_run_on)
    Leverage::SeatRuns.define_singleton_method(:ensure_run_on) do |ctx, seat, credential, work|
      calls << [ seat.id, credential.id, work.class.name, work.id ]
      original.call(ctx, seat, credential, work)
    end
    begin
      assert fail_built(review, criterion).completed?
      ensured = calls
    ensure
      Leverage::SeatRuns.define_singleton_method(:ensure_run_on, original)
    end

    assert_equal %w[review.failed criterion.reopened cost.reported credential.switched], written.map(&:type)
    failed = written.first
    switched = written.last
    assert_equal [ claude_o.id, failed.id, "app", nil, @key ],
      [ switched.subject_id, switched.cause_id, switched.actor_kind, switched.actor_id, switched.command_id ]
    assert_equal({ "from_credential_id" => claude_m.id, "model" => "claude-model-1", "seat_id" => builder.id,
                   "review_id" => nil, "job_id" => nil }, switched.payload)
    assert_equal [ "working", builder.id, claude_o.id ], task.reload.attributes.values_at("state", "holder_seat_id", "credential_id")
    assert_equal [ [ builder.id, claude_o.id, "Task", task.id ] ], ensured
  end

  test "no switch when the first available login is the one recorded" do
    claude_o = @scenario.credential(provider: "claude")
    builder = @scenario.seat(role: "builder", credential: claude_o)
    task, review, criterion = in_review_built_by(builder)

    assert fail_built(review, criterion).completed?
    assert_equal %w[review.failed criterion.reopened cost.reported], written.map(&:type)
    assert_equal claude_o.id, task.reload.credential_id
  end

  test "a builder with no available candidate is busy: Ready, and the wait names credential_limit (HE-14, HE-35)" do
    claude_o = @scenario.credential(provider: "claude")
    builder = @scenario.seat(role: "builder", credential: claude_o)
    task, review, criterion = in_review_built_by(builder)
    @scenario.limit_credential(claude_o, reset_at: @scenario.database_now + 3600)
    @builder.update!(enabled: false)

    assert fail_built(review, criterion).completed?
    assert_equal [ "ready", nil, nil ], task.reload.attributes.values_at("state", "holder_seat_id", "builder_seat_id")
    failed = written.first
    assert_equal [ nil, "credential_limit" ], failed.payload.values_at("lease_seat_id", "wait_cause")
    assert_not_includes written.map(&:type), "credential.switched"
  end
end

# fail_review's rows for a pass whose gate failed (milestone 4 plan SM-6,
# §2.1 rule 7): load_for_gate names the review criterion and the check.
class FailReviewGatedTest < ActiveSupport::TestCase
  include GateSupport

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
  end

  test "the rows of a failed gate: the review criterion reopened, failed_rule_check_id on the review and the event, the round up" do
    rule = custom_rule("task.before_done")
    task, review = ready_for_verdict(@builder, @reviewer)
    check = @scenario.rule_check(task, rule: rule, result: "failed", subject: review)
    request = T::Request.new(command: "pass_review", workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: @reviewer.id, key: "k-verdict", request_hash: nil, params: pass_params(review))
    events = ActiveRecord::Base.transaction(requires_new: true) do
      ctx = @scenario.context(request: request)
      entry = T::Entries::FailReview.new
      entry.load_for_gate(ctx, review: review, seat: @reviewer, check: check)
      entry.perform(ctx)
      ctx.events
    end

    assert_equal %w[review.failed criterion.reopened cost.reported], events.map(&:type)
    review_criterion = Criterion.find_by!(task_id: task.id, kind: "review")
    assert_equal [ [ review_criterion.id ], check.id ], events.first.payload.values_at("failed_criterion_ids", "failed_rule_check_id")
    assert_equal check.id, review.reload.failed_rule_check_id
    assert_equal [ 1, "working" ], task.reload.values_at(:round, :state)
  end
end
