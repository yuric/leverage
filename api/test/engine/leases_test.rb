require "test_helper"

# Leverage::Leases (PRD L116-L123; milestone 2 plan WP5, EN-14, EN-15): a
# builder's lease on a task and a reviewer's on a review. Granting and
# renewing set the due time one lease length after the command's time; a
# paused lease has no running clock and keeps the time it had left; a lease
# is due once its clock has run past the due time. ended_by_expiry? has
# its own test (lease_end_test.rb, WP1's).
class LeasesTest < ActiveSupport::TestCase
  L = Leverage::Leases

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @builder = @scenario.seat(role: "builder")
    @task = @scenario.task(state: "working", builder: @builder)
  end

  def context(at: nil) = @scenario.context(at: at)

  test "grant sets the due time one lease length after the command's time and clears a pause" do
    ctx = context
    @task.update_columns(lease_time_left_while_paused: 120)
    L.grant(ctx, @task)

    assert_equal ctx.at + 600, @task.reload.lease_due_at
    assert_nil @task.lease_time_left_while_paused
  end

  test "grant paused: true starts the lease paused, with the whole length left" do
    ctx = context
    L.grant(ctx, @task, paused: true)

    @task.reload
    assert_nil @task.lease_due_at
    assert_equal 600, @task.lease_time_left_while_paused.to_i
    assert L.paused?(@task)
  end

  test "renew moves the due time on; a paused lease stays paused with the whole length left" do
    ctx = context
    L.renew(ctx, @task)
    assert_equal ctx.at + 600, @task.reload.lease_due_at

    L.pause(ctx, @task)
    L.renew(ctx, @task)
    @task.reload
    assert_nil @task.lease_due_at, "a heartbeat does not restart a paused clock"
    assert_equal 600, @task.lease_time_left_while_paused.to_i
  end

  test "end_lease clears the due time and the pause" do
    ctx = context
    L.pause(ctx, @task)
    L.end_lease(ctx, @task)

    @task.reload
    assert_nil @task.lease_due_at
    assert_nil @task.lease_time_left_while_paused
  end

  test "pause keeps the time left and stops the clock; restart starts it again from the command's time" do
    ctx = context
    @task.update_columns(lease_due_at: ctx.at + 250)
    L.pause(ctx, @task)
    @task.reload
    assert_nil @task.lease_due_at
    assert_equal 250, @task.lease_time_left_while_paused.to_i

    later = context(at: ctx.at + 3600)
    L.restart(later, @task)
    @task.reload
    assert_equal later.at + 250, @task.lease_due_at
    assert_nil @task.lease_time_left_while_paused
  end

  test "a lease paused after its due time keeps no time, and pausing twice changes nothing" do
    ctx = context
    @task.update_columns(lease_due_at: ctx.at - 30)
    L.pause(ctx, @task)
    assert_equal 0, @task.reload.lease_time_left_while_paused.to_i

    @task.update_columns(lease_time_left_while_paused: 90)
    L.pause(ctx, @task)
    assert_equal 90, @task.reload.lease_time_left_while_paused.to_i
  end

  test "restart at: a given time runs the clock again from that time (review)" do
    ctx = @scenario.context
    L.grant(ctx, @task, paused: true)
    left = @task.reload.lease_time_left_while_paused.to_f
    L.restart(@scenario.context(at: ctx.at + 90), @task, at: ctx.at + 30)

    assert_equal ctx.at + 30 + left, @task.reload.lease_due_at
  end

  test "restart of a lease that is not paused changes nothing" do
    ctx = context
    due = @task.lease_due_at
    L.restart(ctx, @task)

    assert_equal due, @task.reload.lease_due_at
  end

  test "due? holds from the due time on, and never for a paused lease or no lease" do
    now = @scenario.database_now
    @task.update_columns(lease_due_at: now)
    assert L.due?(@task, now), "a lease is due at its due time"
    assert L.due?(@task, now + 1)
    refute L.due?(@task, now - 1)

    @task.update_columns(lease_time_left_while_paused: 10)
    refute L.due?(@task, now + 1), "a paused lease is never due, whatever its due column says"

    @task.update_columns(lease_due_at: nil, lease_time_left_while_paused: nil)
    refute L.due?(@task, now + 1)
  end

  test "live? is what a read uses: a lease past its due time counts as ended before any timer writes it" do
    now = @scenario.database_now
    @task.update_columns(lease_due_at: now + 5)
    assert L.live?(@task, now)
    refute L.live?(@task, now + 5)

    @task.update_columns(lease_due_at: nil, lease_time_left_while_paused: 5)
    assert L.live?(@task, now + 3600), "a paused lease is live"

    @task.update_columns(lease_due_at: nil, lease_time_left_while_paused: nil)
    refute L.live?(@task, now)
  end

  test "the same works on a review's lease" do
    reviewer = @scenario.seat(role: "reviewer")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    ctx = context

    L.grant(ctx, review)
    assert_equal ctx.at + 600, review.reload.lease_due_at
    L.pause(ctx, review)
    assert L.paused?(review.reload)
    L.restart(ctx, review)
    assert_equal ctx.at + 600, review.reload.lease_due_at
    refute L.due?(review, ctx.at)
  end
end
