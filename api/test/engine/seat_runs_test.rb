require "test_helper"

# Leverage::SeatRuns (milestone 2 plan §2.1, IN-17, IN-30, IN-40, IF-21,
# L148): what a stopped run and a removed seat change, called inside a
# command's transaction by report_run_stopped, issue_helper_token and
# remove_seat.
class SeatRunsTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @scenario.owner
  end

  def ctx = @scenario.context

  test "a stopped run ends the seat's token and releases only a review whose lease is live" do
    reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential, run_state: "running")
    live = @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)

    events = Leverage::SeatRuns.run_stopped(ctx, reviewer)

    assert_equal [ "review.released" ], events.map(&:type)
    assert_equal [ "stopped", nil ], [ reviewer.reload.run_state, reviewer.token_hash ]
    assert_nil live.reload.reviewer_seat_id
  end

  test "a stopped run leaves a review past its due time alone" do
    reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential, run_state: "running")
    review = @scenario.make_due(@scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer))

    assert_empty Leverage::SeatRuns.run_stopped(ctx, reviewer)
    assert_equal reviewer.id, review.reload.reviewer_seat_id
  end

  test "a removed seat's Working task is released with seat_removed; one with a paused lease too" do
    builder = @scenario.seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder)
    task.update_columns(lease_due_at: nil, lease_time_left_while_paused: 5.minutes)
    context = ctx
    removed = context.emit("seat.removed", subject: builder)

    released = Leverage::SeatRuns.release_working_task(context, builder, reason: "seat_removed", cause: removed)

    assert_equal "task.released", released.type
    assert_equal [ "ready", nil, nil, nil ],
      [ task.reload.state, task.holder_seat_id, task.lease_due_at, task.lease_time_left_while_paused ]
  end

  test "the inputs of a start request are the seat's role, provider, model and effort, with null for empty" do
    seat = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"), model: "", effort: "low")

    assert_equal({ "role" => "reviewer", "provider" => "codex", "model" => nil, "effort" => "low" },
      Leverage::SeatRuns.start_params(seat))
  end
end
