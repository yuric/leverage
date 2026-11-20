require "test_helper"

# Leverage::Eligibility (PRD L544-L545, L548; milestone 2 plan EN-8, EN-15,
# EN-23): which seat may claim, the next task and the next review a seat
# gets, and the refusals that say a seat may not act on a task or a review.
class EligibilityTest < ActiveSupport::TestCase
  E = Leverage::Eligibility

  # A gating that filters given tasks and reviews out of a claim.
  class Filtering < Leverage::Gating::NoRules
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

    Leverage::Gating.implementation = Leverage::Gating::NoRules.new
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
    assert_nil E.next_task(@builder.reload), "a seat with no run"

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
end
