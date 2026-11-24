require "test_helper"
require_relative "provider_world"

# Leverage::Eligibility (PRD L544-L545, L548; milestone 2 plan EN-8, EN-15,
# EN-23): which seat may claim, the next task and the next review a seat
# gets, and the refusals that say a seat may not act on a task or a review.
class EligibilityTest < ActiveSupport::TestCase
  E = Leverage::Eligibility

  # A gating that filters given tasks and reviews out of a claim.
  class Filtering < Leverage::Rules::Engine
    def initialize(tasks: [], reviews: [])
      super()
      @tasks = tasks
      @reviews = reviews
    end

    def claimable_filter(seat_id:, kind:)
      Leverage::Gating::ClaimFilter.new(excluded_task_ids: @tasks, excluded_review_ids: @reviews)
    end
  end

  setup do
    @scenario = Scenario.new
    @credential = @scenario.credential
    @builder = @scenario.seat(role: "builder", credential: @credential)
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
  end

  def ready(priority: "normal", created_at: nil, **options)
    task = @scenario.task(state: "ready", priority: priority, **options)
    task.update_columns(created_at: created_at) if created_at
    task
  end

  test "the next task is by priority, then age, then id" do
    now = @scenario.database_now
    old_low = ready(priority: "low", created_at: now - 300)
    new_normal = ready(created_at: now - 10)
    old_normal = ready(created_at: now - 200)
    high = ready(priority: "high", created_at: now)

    order = []
    4.times do
      task = E.next_task(@builder)
      order << task
      task.update_columns(state: "backlog")
    end
    assert_equal [ high, old_normal, new_normal, old_low ].map(&:id), order.map(&:id)
    assert_nil E.next_task(@builder)
  end

  test "tasks of one age are taken by id" do
    now = @scenario.database_now
    tasks = Array.new(3) { ready(created_at: now) }
    assert_equal tasks.map(&:id).min, E.next_task(@builder).id
  end

  test "the next task skips held tasks, tasks above the seat's strength and tasks the gating filters out" do
    held = ready
    Hold.create!(workspace_id: held.workspace_id, task_id: held.id, reason: "owner_hold", opened_at: @scenario.database_now,
      opened_by_kind: "owner")
    strong = ready
    strong.update_columns(minimum_strength_rank: @builder.strength_rank + 1)
    filtered = ready
    Leverage::Gating.implementation = Filtering.new(tasks: [ filtered.id ])
    assert_nil E.next_task(@builder)

    fit = ready
    fit.update_columns(minimum_strength_rank: @builder.strength_rank)
    assert_equal fit.id, E.next_task(@builder).id
  end

  test "a free, enabled builder may claim; a seat that connects on its own may too" do
    assert E.may_claim?(@builder, :task)
    assert E.may_claim?(@scenario.seat(role: "builder", provider: "claude"), :task)
  end

  test "a seat may not claim when it is disabled, paused, removed or of the other role" do
    refute E.may_claim?(@scenario.seat(role: "builder", enabled: false), :task)
    refute E.may_claim?(@scenario.seat(role: "builder", paused: true), :task)
    refute E.may_claim?(@scenario.remove(@scenario.seat(role: "builder")), :task)
    refute E.may_claim?(@reviewer, :task)
    refute E.may_claim?(@builder, :review)
  end

  test "a seat that holds a task or a review may not claim" do
    @scenario.task(state: "working", builder: @builder)
    refute E.may_claim?(@builder, :task)

    task = @scenario.task(state: "in_review")
    @scenario.review(task, reviewer: @reviewer)
    refute E.may_claim?(@reviewer, :review)
  end

  test "a seat the app runs may claim only while its own credential is active and not limited (EN-8)" do
    signed_out = @scenario.credential(added: false)
    refute E.may_claim?(@scenario.seat(role: "builder", credential: signed_out), :task)

    limited = @scenario.credential(limited_until: @scenario.database_now + 3600)
    refute E.may_claim?(@scenario.seat(role: "builder", credential: limited), :task)

    reset = @scenario.credential(limited_until: @scenario.database_now - 1)
    assert E.may_claim?(@scenario.seat(role: "builder", credential: reset), :task)
  end

  test "the next review is the oldest open review of an unheld task In review" do
    now = @scenario.database_now
    newer = @scenario.task(state: "in_review")
    older = @scenario.task(state: "in_review")
    Review.where(task_id: newer.id).update_all(created_at: now)
    Review.where(task_id: older.id).update_all(created_at: now - 60)
    assert_equal Review.find_by(task_id: older.id).id, E.next_review(@reviewer).id

    @scenario.review(older, reviewer: @scenario.seat(role: "reviewer"))
    assert_equal Review.find_by(task_id: newer.id).id, E.next_review(@reviewer).id

    Hold.create!(workspace_id: newer.workspace_id, task_id: newer.id, reason: "owner_hold", opened_at: now,
      opened_by_kind: "owner")
    assert_nil E.next_review(@reviewer)
  end

  test "the next review skips reviews the gating filters out and tasks the seat has built" do
    task = @scenario.task(state: "in_review")
    review = Review.find_by(task_id: task.id)
    Leverage::Gating.implementation = Filtering.new(reviews: [ review.id ])
    assert_nil E.next_review(@reviewer)

    Leverage::Gating.implementation = Leverage::Rules::Engine.new
    @scenario.append("task.claimed", task: task, actor_kind: "seat", actor_id: @reviewer.id,
      payload: { seat_id: @reviewer.id, credential_id: nil, model: nil })
    assert_nil E.next_review(@reviewer)
  end

  test "the previous builder is free when it holds nothing and is enabled, not paused and not removed" do
    assert E.builder_free?(@builder)
    @scenario.task(state: "working", builder: @builder)
    refute E.builder_free?(@builder)
    refute E.builder_free?(@scenario.seat(role: "builder", paused: true))
    refute E.builder_free?(@scenario.seat(role: "builder", enabled: false))
    refute E.builder_free?(@scenario.remove(@scenario.seat(role: "builder")))
    refute E.builder_free?(nil)
  end

  test "a holder's task refusals: not_holder, forbidden, lease_expired and task_cancelled" do
    task = @scenario.task(state: "working", builder: @builder)
    assert_equal [], E.task_refusals(task, @builder)
    other = @scenario.seat(role: "builder")
    assert_equal [ "not_holder" ], E.task_refusals(task, other)
    assert_equal %w[not_holder forbidden], E.task_refusals(task, @reviewer)

    task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.lease_expired", task: task, payload: { wait_cause: nil })
    assert_equal %w[lease_expired], E.task_refusals(task, @builder)
    assert_equal %w[not_holder], E.task_refusals(task, other)
  end

  test "the seat that held a cancelled task is told task_cancelled; any other seat not_holder" do
    task = @scenario.task(state: "working", builder: @builder)
    task.update!(state: "cancelled", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.cancelled", task: task, actor_kind: "owner", actor_id: @scenario.owner.id)

    assert_equal %w[task_cancelled], E.task_refusals(task, @builder)
    assert_equal %w[not_holder], E.task_refusals(task, @scenario.seat(role: "builder"))
  end

  test "a reviewer's review refusals" do
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: @reviewer)
    assert_equal [], E.review_refusals(review, @reviewer)
    assert_equal %w[not_holder], E.review_refusals(review, @scenario.seat(role: "reviewer"))
    assert_equal %w[not_holder forbidden], E.review_refusals(review, @builder)

    review.update!(reviewer_seat_id: nil, lease_due_at: nil)
    @scenario.append("review.lease_expired", task: task, subject: review)
    assert_equal %w[lease_expired], E.review_refusals(review, @reviewer)

    other = @scenario.seat(role: "reviewer")
    claimed = @scenario.review(task, reviewer: other)
    task.update!(state: "cancelled")
    claimed.update!(reviewer_seat_id: nil, lease_due_at: nil)
    @scenario.append("task.cancelled", task: task, actor_kind: "owner", actor_id: @scenario.owner.id)
    assert_equal %w[task_cancelled], E.review_refusals(claimed, other)
  end

  test "a review with a verdict is held by nobody" do
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: @reviewer)
    review.update!(verdict: "failed", lease_due_at: nil)
    assert_equal %w[not_holder], E.review_refusals(review, @reviewer)
  end

  # HD-4 (milestone 3 plan §2.1 rules 1 to 3): a seat the app runs may
  # claim only when one of its candidates is available for the work and its
  # run is on the first of them, so the claim records the account that does
  # the work. A seat that connects on its own has no candidates and no run
  # the app places.

  test "a seat whose run is not on its first available candidate may not claim (HD-4)" do
    task = ready
    below = Credential.find(@reviewer.credential_id)
    @scenario.run(@builder, on: below)
    refute E.may_claim?(@builder.reload, :task)
    assert_nil E.next_task(@builder)

    @scenario.run(@builder, on: nil)
    assert_equal task.id, E.next_task(@builder.reload).id, "a token issued before its run was recorded is on its own login"

    @scenario.run(@builder)
    assert_equal task.id, E.next_task(@builder.reload).id
  end

  test "a seat whose own login is limited claims on the next available candidate once its run is there (HD-4)" do
    task = ready
    below = Credential.find(@reviewer.credential_id)
    @scenario.limit_credential(@credential, reset_at: @scenario.database_now + 3600)
    assert_nil E.next_task(@builder.reload), "its run is still on its own login"

    @scenario.run(@builder, on: below)
    assert E.may_claim?(@builder.reload, :task)
    assert_equal task.id, E.next_task(@builder).id
    assert_equal task.id, E.next_task(@builder, at: @scenario.database_now).id
  end

  test "a reviewer is placed the same way (HD-4)" do
    task = @scenario.task(state: "in_review")
    review = Review.find_by!(task_id: task.id)
    @scenario.sign_out_credential(Credential.find(@reviewer.credential_id))
    assert_nil E.next_review(@reviewer.reload)

    later = @scenario.credential(provider: "grok")
    @scenario.run(@reviewer, on: later)
    assert_equal review.id, E.next_review(@reviewer.reload).id
  end

  test "a limit that has reset counts as available at the time asked (HE-3)" do
    task = ready
    @scenario.limit_credential(@credential, reset_at: @scenario.database_now + 60)
    assert_nil E.next_task(@builder.reload)
    assert_equal task.id, E.next_task(@builder, at: @scenario.database_now + 61).id
  end

  test "a builder the app runs is free for a fresh lease only if one of its candidates is available (HE-14)" do
    task = @scenario.task(state: "in_review", builder: @builder)
    assert E.builder_free?(@builder, task)

    @scenario.limit_credential(Credential.find(@reviewer.credential_id))
    @scenario.limit_credential(@credential, reset_at: @scenario.database_now + 3600)
    refute E.builder_free?(@builder.reload, task)
    assert E.builder_free?(@builder, task, at: @scenario.database_now + 3601)

    @scenario.credential(provider: "codex")
    assert E.builder_free?(@builder, task), "a candidate below is available; its run need not be on it"
  end

  test "a task is on hold while any hold is open" do
    task = @scenario.task(state: "ready")
    refute E.on_hold?(task)
    hold = Hold.create!(workspace_id: task.workspace_id, task_id: task.id, reason: "owner_hold",
      opened_at: @scenario.database_now, opened_by_kind: "owner")
    assert E.on_hold?(task)
    hold.update!(closed_at: @scenario.database_now)
    refute E.on_hold?(task)
  end

  # --- Milestone 4: the claim order and the provider rule (plan WP9) -----------

  # A failed task.before_claim check of the seat on the task's current
  # contract version and round, overridden by the owner (L910, RC-23).
  def overridden_claim_check(task, seat, contract_version: task.contract_version, round: task.round)
    rule = @claim_rule ||= @scenario.rule(hook: "task.before_claim")
    inputs = { "contract_version" => contract_version, "seat_id" => seat.id }
    check = @scenario.rule_check(task, rule: rule, result: "failed", hook: "task.before_claim", round: round, subject: seat,
      input_hash: Leverage::Gating.input_hash(hook: "task.before_claim", inputs: inputs))
    check.update!(overridden_at: @scenario.database_now, overridden_by_user_id: @scenario.owner.id,
      override_reason: "Made-up reason.")
    check
  end

  test "claim-next gives first a Ready task on which the seat has an overridden failed claim check of the current inputs (RD-14)" do
    now = @scenario.database_now
    high = ready(priority: "high", created_at: now - 300)
    overridden = ready(priority: "low", created_at: now)
    overridden_claim_check(overridden, @builder)

    assert_equal overridden.id, E.next_task(@builder).id
    assert_equal high.id, E.next_task(@scenario.seat(role: "builder")).id, "another seat's override is not this seat's"
  end

  test "an override of another contract version, another round, or not overridden at all changes nothing (RD-14)" do
    now = @scenario.database_now
    first = ready(created_at: now - 300)
    stale = ready(created_at: now)
    overridden_claim_check(stale, @builder, contract_version: 0)
    overridden_claim_check(stale, @builder, round: 3)
    @scenario.rule_check(stale, rule: @claim_rule, result: "failed", hook: "task.before_claim", subject: @builder,
      input_hash: Leverage::Gating.input_hash(hook: "task.before_claim",
        inputs: { "contract_version" => stale.contract_version, "seat_id" => @builder.id }))

    assert_equal first.id, E.next_task(@builder).id
  end

  # RD-50: the provider the rule is asked about is that of the account the
  # review would run on: the seat's run's (seats.run_credential_id), or the
  # seat's own for one that connects on its own.
  test "the next review asks the provider rule about the provider of the account the seat's run is on (RD-50)" do
    task = @scenario.task(state: "in_review", builder: @builder)
    review = Review.find_by!(task_id: task.id)
    own = @scenario.credential(provider: "claude")
    below = @scenario.credential(provider: "grok")
    seat = @scenario.seat(role: "reviewer", credential: own)
    @scenario.limit_credential(own, reset_at: @scenario.database_now + 3600)
    @scenario.run(seat, on: below)
    Leverage::Gating.implementation = ProviderWorld.new

    assert_equal review.id, E.next_review(seat.reload).id
    assert_nil E.next_review(@scenario.seat(role: "reviewer", provider: "claude")), "one that connects on its own: its own"
    assert_equal review.id, E.next_review(@scenario.seat(role: "reviewer", provider: "grok")).id
  end

  test "claim-next names, in order, the reviews before the one it takes that the rule or the claim filter keeps from the seat (RC-50)" do
    now = @scenario.database_now
    tasks = [ 300, 200, 100, 50 ].map do |ago|
      task = @scenario.task(state: "in_review", builder: @builder)
      Review.where(task_id: task.id).update_all(created_at: now - ago)
      task
    end
    reviews = tasks.map { |task| Review.find_by!(task_id: task.id) }
    seat = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
    built = { tasks[0].id => %w[codex], tasks[1].id => %w[claude], tasks[2].id => %w[claude], tasks[3].id => %w[codex] }
    Leverage::Gating.implementation = ProviderWorld.new(built_by: built, reviews: { reviews[1].id => tasks[1].id },
      past_holders: { tasks[1].id => [ seat.id ] })

    review, skipped = E.review_and_skipped(seat)
    assert_equal reviews[2].id, review.id
    assert_equal [ reviews[0].id, reviews[1].id ], skipped.map(&:id)
    assert_equal reviews[2].id, E.next_review(seat).id

    reviews[2].update!(reviewer_seat_id: @scenario.seat(role: "reviewer").id)
    assert_equal [ nil, [ reviews[0].id, reviews[1].id, reviews[3].id ] ], E.review_and_skipped(seat).then { |taken, left| [ taken, left.map(&:id) ] }
    assert_equal [ nil, [] ], E.review_and_skipped(@builder), "a seat that may not claim a review skips nothing"
  end

  test "may_review?: a reviewer that never built the task, enabled, not paused, not removed, on an account the rule allows (RD-51)" do
    task = @scenario.task(state: "in_review", builder: @builder)
    review = Review.find_by!(task_id: task.id)
    Leverage::Gating.implementation = ProviderWorld.new
    at = @scenario.database_now

    assert E.may_review?(@reviewer, review, at: at), "codex never built it and is allowed"
    refute E.may_review?(@scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "claude")), review, at: at)
    refute E.may_review?(@scenario.seat(role: "reviewer", provider: "claude"), review, at: at)
    assert E.may_review?(@scenario.seat(role: "reviewer", provider: "grok"), review, at: at)
    refute E.may_review?(@scenario.seat(role: "reviewer", provider: "grok", enabled: false), review, at: at)
    refute E.may_review?(@scenario.pause_seat(@scenario.seat(role: "reviewer", provider: "grok")), review, at: at)
    refute E.may_review?(@scenario.remove(@scenario.seat(role: "reviewer", provider: "grok")), review, at: at)
    refute E.may_review?(@scenario.seat(role: "builder", provider: "grok"), review, at: at)

    @scenario.review(task, reviewer: @reviewer)
    assert E.may_review?(@reviewer, review, at: at), "a reviewer busy on a review may still review it later"

    limited = @scenario.credential(provider: "codex")
    waiting = @scenario.seat(role: "reviewer", credential: limited)
    @scenario.limit_credential(limited, reset_at: at + 3600)
    refute E.may_review?(waiting.reload, review, at: at), "no account to review on"
    assert E.may_review?(waiting, review, at: at + 3601)
  end

  test "may_review?: the account its run belongs on must be one rule 3 keeps for the review (a minimum strength rank)" do
    task = @scenario.task(state: "in_review", builder: @builder)
    task.update_columns(minimum_strength_rank: 2)
    review = Review.find_by!(task_id: task.id)
    Leverage::Gating.implementation = ProviderWorld.new
    own = @scenario.credential(provider: "codex")
    @scenario.credential(provider: "grok", strength_rank: 1)
    seat = @scenario.seat(role: "reviewer", credential: own, strength_rank: 2)
    at = @scenario.database_now
    @scenario.limit_credential(own, reset_at: at + 3600)

    refute E.may_review?(seat.reload, review, at: at), "its run belongs on a weaker login of another provider group"
    assert E.may_review?(seat, review, at: at + 3601)
  end

  test "may_review?: a reviewer that built the task may not, whatever its provider (L455)" do
    task = @scenario.task(state: "in_review", builder: @builder)
    review = Review.find_by!(task_id: task.id)
    @scenario.append("task.claimed", task: task, actor_kind: "seat", actor_id: @reviewer.id,
      payload: { seat_id: @reviewer.id, credential_id: @reviewer.credential_id, model: nil })
    refute E.may_review?(@reviewer, review, at: @scenario.database_now)
  end
  test "General may claim a task returned by another provider group and review a task it never built" do
    general = @scenario.seat(role: "general", provider: "codex")
    task = @scenario.task(state: "working", builder: @builder)
    task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil, lease_due_at: nil)
    review_task = @scenario.task(state: "in_review", builder: @builder)

    assert_equal task, E.next_task(general)
    assert_equal review_task.id, E.next_review(general)&.task_id
  end

  test "busy and paused builders stand for a task but cannot claim it now" do
    task = ready
    busy = @scenario.seat(role: "general")
    paused = @scenario.seat(role: "general", paused: true)
    @scenario.task(state: "working", builder: busy)

    assert_respond_to E, :standing?
    assert_respond_to E, :momentary?
    [ busy, paused ].each do |seat|
      assert E.standing?(seat, task, rank: seat.strength_rank)
      refute E.momentary?(seat, task, at: @scenario.database_now)
    end
  end

  %i[removed disabled paused].each do |state|
    test "a General reviewer can build a returned task when the other builder is #{state}" do
      general = @scenario.seat(role: "general", provider: "codex")
      task = @scenario.task(state: "in_review", builder: @builder)
      review = @scenario.review(task, reviewer: general)
      review.update!(reviewer_seat_id: nil, lease_due_at: nil)
      task.update!(state: "ready", holder_seat_id: nil, builder_seat_id: nil)
      assert_nil E.next_task(general), "the other builder still stands for this task"

      changes = { removed: { removed_at: @scenario.database_now }, disabled: { enabled: false }, paused: { paused: true } }
      @builder.update!(changes.fetch(state))
      assert_equal task, E.next_task(general)
    end
  end

  %i[task review job provisional].each do |work|
    test "a General seat with a #{work} gets no new task or review" do
      general = @scenario.seat(role: "general", provider: "codex")
      ready
      review_task = @scenario.task(state: "in_review", builder: @builder)
      case work
      when :task then @scenario.task(state: "working", builder: general)
      when :review then @scenario.review(review_task, reviewer: general)
      when :job then @scenario.job(kind: "contract_draft", task: @scenario.task, state: "claimed", seat: general)
      when :provisional then ready.update!(holder_seat_id: general.id)
      end

      assert_nil E.next_task(general)
      assert_nil E.next_review(general)
    end
  end
end
