require "test_helper"
require_relative "entries/call_spy"
require_relative "entries/pending_ends_support"

# Leverage::SeatRuns (milestone 2 plan §2.1, IN-17, IN-30, IN-40, IF-21,
# L148; milestone 3 plan HD-1, HD-3, HD-4, HD-10, HE-5, HE-35): where a
# seat's run belongs, the one start request that puts it there, and what a
# stopped, interrupted or removed run changes, called inside a command's
# transaction.
#
# Milestone 4 (plan WP5b, §2.1 rule 11): a stopped run, a treated-as-stopped
# run (reconcile), a removed seat and a disabled seat call
# PendingTransitions.cancel, with invalid_state, for the pending pass of the
# review they release, the pending submit of the Working task they release
# and the provisional claim they hold, before the release's event.
class SeatRunsTest < ActiveSupport::TestCase
  include CallSpy
  include PendingEndsSupport

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
    assert_equal [ "ready", nil, nil, nil, nil ],
      [ task.reload.state, task.holder_seat_id, task.builder_seat_id, task.lease_due_at, task.lease_time_left_while_paused ]
  end

  test "the inputs of a start request are the seat's role, provider, model and effort, with null for empty" do
    seat = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"), model: "", effort: "low")

    assert_equal({ "role" => "reviewer", "provider" => "codex", "model" => nil, "effort" => "low" },
      Leverage::SeatRuns.start_params(seat))
  end

  # --- placement (HD-1, HD-4) ----------------------------------------------------------

  def starts(seat) = HelperRequest.where(seat_id: seat.id, kind: "start_seat").order(:requested_at, :id).to_a

  test "an idle seat's run belongs on its first available candidate, and on its own when none is" do
    own = @scenario.credential
    below = @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own)

    assert_equal [ own.id, nil ], placed(seat)
    @scenario.limit_credential(own, reset_at: @scenario.database_now + 3600)
    assert_equal [ below.id, nil ], placed(seat), "the first available candidate"
    @scenario.limit_credential(below)
    assert_equal [ own.id, nil ], placed(seat), "with none available, its own"
  end

  test "a seat that holds a task with no credential hold continues it on the credential recorded for it" do
    own = @scenario.credential
    other = @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own)
    task = @scenario.task(state: "working", builder: seat)
    task.update!(credential_id: other.id)
    @scenario.hold(task, reason: "seat_paused")

    placement = Leverage::SeatRuns.placement(seat)

    assert_equal [ other.id, task.id ], [ placement.credential&.id, placement.work&.id ]
    assert_kind_of Task, placement.work
  end

  test "a seat that holds a task under a credential hold has no run to place" do
    own = @scenario.credential
    seat = @scenario.seat(credential: own)
    task = @scenario.task(state: "working", builder: seat)
    @scenario.limit_credential(own, reset_at: @scenario.database_now + 3600, seat: seat, task: task)
    @scenario.hold(task, reason: "credential_limit", credential: own, item: false)

    placement = Leverage::SeatRuns.placement(seat)

    assert_nil placement.credential
    assert_equal task.id, placement.work&.id
  end

  test "a reviewer that holds a review continues it on the credential recorded for the review" do
    own = @scenario.credential
    other = @scenario.credential(provider: "grok")
    reviewer = @scenario.seat(role: "reviewer", credential: own)
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)
    review.update!(credential_id: other.id)

    placement = Leverage::SeatRuns.placement(reviewer)

    assert_equal [ other.id, review.id ], [ placement.credential&.id, placement.work&.id ]
    assert_kind_of Review, placement.work
  end

  test "a seat that connects on its own has no placement" do
    placement = Leverage::SeatRuns.placement(@scenario.seat(provider: "codex"))

    assert_equal [ nil, nil ], [ placement.credential, placement.work ]
  end

  # --- ensure_run_on (HD-1, HE-5) ------------------------------------------------------

  test "ensure_run_on queues one start on the credential with its provider, the seat's model within its group, and the task" do
    own = @scenario.credential
    same = @scenario.credential(provider: "claude", model: "credential-model", effort: "high")
    seat = @scenario.seat(credential: own, model: "seat-model", effort: "low", wanted_running: true)
    task = @scenario.task(state: "working", builder: seat)

    request = Leverage::SeatRuns.ensure_run_on(ctx, seat, same, task)

    assert_equal [ "start_seat", "queued", seat.id, same.id ],
      [ request.kind, request.state, request.seat_id, request.credential_id ]
    assert_equal({ "role" => "builder", "provider" => "claude", "model" => "seat-model", "effort" => "low",
                   "task_id" => task.id }, request.params)
    assert_equal [ request ], starts(seat)
  end

  test "a start on another provider's credential names that provider, its model and its effort, and the review" do
    own = @scenario.credential
    grok = @scenario.credential(provider: "grok", model: "grok-made-up-model", effort: "")
    reviewer = @scenario.seat(role: "reviewer", credential: own, model: "seat-model", wanted_running: true)
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)

    request = Leverage::SeatRuns.ensure_run_on(ctx, reviewer, grok, review)

    assert_equal({ "role" => "reviewer", "provider" => "grok", "model" => "grok-made-up-model", "effort" => nil,
                   "review_id" => review.id }, request.params)
    assert_equal grok.id, request.credential_id
  end

  test "an idle start names no work, and the params hold no name and no token" do
    own = @scenario.credential
    seat = @scenario.seat(credential: own, wanted_running: true, token: false)

    request = Leverage::SeatRuns.ensure_run_on(ctx, seat, own, nil)

    assert_equal %w[effort model provider role], request.params.keys.sort
    refute_includes request.attributes.to_json, seat.name
    refute_includes request.attributes.to_json, own.name
    assert_empty request.params.keys.grep(/name|token/)
  end

  test "ensure_run_on queues nothing while an unfinished start exists, nor when the run is already on the credential" do
    own = @scenario.credential
    other = @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own, wanted_running: true)

    assert_nil Leverage::SeatRuns.ensure_run_on(ctx, seat, own, nil), "its run is on its own credential"
    first = Leverage::SeatRuns.ensure_run_on(ctx, seat, other, nil)
    first.update!(state: "picked_up", picked_up_at: @scenario.database_now)
    assert_nil Leverage::SeatRuns.ensure_run_on(ctx, seat, other, nil)
    assert_equal [ first ], starts(seat)

    first.update!(state: "finished", finished_at: @scenario.database_now)
    @scenario.run(seat, on: nil, state: "stopped")
    assert_not_nil Leverage::SeatRuns.ensure_run_on(ctx, seat, other, nil), "a seat with no run gets a start"
  end

  test "ensure_run_on starts no seat the owner stopped or removed, and none that connects on its own" do
    own = @scenario.credential
    other = @scenario.credential(provider: "codex")
    stopped = @scenario.seat(credential: own, wanted_running: false)
    removed = @scenario.remove(@scenario.seat(credential: own, wanted_running: true))
    alone = @scenario.seat(provider: "codex")

    [ stopped, removed, alone ].each do |seat|
      assert_nil Leverage::SeatRuns.ensure_run_on(ctx, seat, other, nil)
    end
    assert_equal 0, HelperRequest.where(workspace_id: @scenario.workspace_id, kind: "start_seat").count
  end

  # --- the end of a run (HD-3, HD-10) --------------------------------------------------

  test "a run ended by an interruption is stopped, keeps the reason, ends its token and has no credential" do
    reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential, run_state: "running")
    review = @scenario.review(@scenario.task(state: "in_review"), reviewer: reviewer)

    Leverage::SeatRuns.ended_by_interruption(reviewer, "limit")

    reviewer.reload
    assert_equal [ "stopped", nil, nil, "limit" ],
      [ reviewer.run_state, reviewer.token_hash, reviewer.run_credential_id, reviewer.run_stop_reason ]
    assert_equal reviewer.id, review.reload.reviewer_seat_id, "it releases nothing: the report's row does"
  end

  test "a stopped run keeps its reason and has no credential" do
    seat = @scenario.seat(credential: @scenario.credential, run_state: "running")

    Leverage::SeatRuns.run_stopped(ctx, seat, reason: "error")

    assert_equal [ "stopped", nil, "error" ], [ seat.reload.run_state, seat.run_credential_id, seat.run_stop_reason ]
  end

  test "the token issued for a start puts the seat's run on the start's credential" do
    own = @scenario.credential
    other = @scenario.credential(provider: "codex")
    seat = @scenario.seat(credential: own, token: false)
    start = HelperRequest.create!(workspace_id: @scenario.workspace_id, kind: "start_seat", seat_id: seat.id,
      credential_id: other.id, state: "picked_up", requested_at: @scenario.database_now, params: {})

    token = Leverage::SeatRuns.issue_token(seat, start)

    assert_equal [ Leverage::Tokens.digest(token), other.id ], [ seat.reload.token_hash, seat.run_credential_id ]
  end

  # --- a Working task released by the seat (HE-35, SM-15) ------------------------------

  test "a release with no seat-bound hold carries the wait_ready cause and closes none" do
    own = @scenario.credential
    seat = @scenario.seat(credential: own)
    other = @scenario.seat(credential: @scenario.credential(provider: "codex"))
    @scenario.task(state: "working", builder: seat)
    @scenario.limit_credential(Credential.find(other.credential_id), reset_at: @scenario.database_now + 3600)
    context = ctx
    removed = context.emit("seat.removed", subject: seat)
    seat.update!(removed_at: context.at)

    calls = spy_on(Leverage::Holds, :close_seat_bound) do
      @released = Leverage::SeatRuns.release_working_task(context, seat, reason: "seat_removed", cause: removed)
    end

    assert_empty calls
    assert_equal({ "reason" => "seat_removed", "wait_cause" => "credential_limit" }, @released.payload,
      "the one other builder has no available account (HE-35)")
  end

  test "a release with a seat-bound hold leaves the cause to hold.closed and asks Holds to close the seat's holds" do
    own = @scenario.credential
    seat = @scenario.seat(credential: own)
    other = @scenario.seat(credential: @scenario.credential(provider: "codex"))
    task = @scenario.task(state: "working", builder: seat)
    @scenario.limit_credential(own, reset_at: @scenario.database_now + 3600, seat: seat, task: task)
    @scenario.hold(task, reason: "credential_limit", credential: own, item: false)
    @scenario.limit_credential(Credential.find(other.credential_id), reset_at: @scenario.database_now + 3600)
    context = ctx
    removed = context.emit("seat.removed", subject: seat)
    seat.update!(removed_at: context.at)

    calls = spy_on(Leverage::Holds, :close_seat_bound) do
      @released = Leverage::SeatRuns.release_working_task(context, seat, reason: "seat_removed", cause: removed)
    end

    assert_nil @released.payload.fetch("wait_cause")
    assert_equal 1, calls.size
    call = calls.first
    assert_equal [ context, task.id ], [ call.arguments.first, call.arguments.last.id ]
    assert_equal [ @released, "credential_limit" ], [ call.keywords[:cause], call.keywords[:wait_cause] ]
  end

  private

  def placed(seat)
    placement = Leverage::SeatRuns.placement(seat)
    [ placement.credential&.id, placement.work&.id ]
  end

  test "a stopped run cancels the pending pass of the review it releases, before review.released" do
    reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential, run_state: "running")
    task = @scenario.task(state: "in_review")
    @scenario.review(task, reviewer: reviewer)
    pending = @scenario.pending_transition(task, command: "pass_review", requester: reviewer)
    context = ctx
    events = nil
    calls = recording_cancels { events = Leverage::SeatRuns.run_stopped(context, reviewer) }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", []) ], calls
    assert_equal %w[review.released], events.map(&:type)
  end

  test "a stopped run cancels for the review it releases and for none when it holds none, keeping the actor it is given" do
    reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential, run_state: "running")
    task = @scenario.task(state: "in_review")
    @scenario.review(task, reviewer: reviewer)
    pending = @scenario.pending_transition(task, command: "pass_review", requester: reviewer)
    calls = recording_cancels do
      events = Leverage::SeatRuns.run_stopped(ctx, reviewer, actor_kind: "app", actor_id: nil)
      assert_equal [ [ "app", nil ] ], events.map { |event| [ event.actor_kind, event.actor_id ] }
    end

    assert_equal [ pending.id ], calls.map(&:pending_id)

    idle = @scenario.seat(role: "reviewer", credential: @scenario.credential, run_state: "running")
    assert_empty recording_cancels { Leverage::SeatRuns.run_stopped(ctx, idle) }
  end

  test "a run treated as stopped by a new helper token cancels the pending pass of its review (reconcile)" do
    reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential, run_state: "running")
    task = @scenario.task(state: "in_review")
    review = @scenario.review(task, reviewer: reviewer)
    pending = @scenario.pending_transition(task, command: "pass_review", requester: reviewer)
    calls = recording_cancels { Leverage::SeatRuns.reconcile(ctx) }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", []) ], calls
    assert_nil review.reload.reviewer_seat_id
  end

  test "a removed seat cancels its pending submit and its pending pass, each before its release" do
    builder = @scenario.seat(role: "builder")
    working = @scenario.task(state: "working", builder: builder)
    submit = @scenario.pending_transition(working, command: "submit", requester: builder)
    reviewer = @scenario.seat(role: "reviewer")
    in_review = @scenario.task(state: "in_review")
    @scenario.review(in_review, reviewer: reviewer)
    pass = @scenario.pending_transition(in_review, command: "pass_review", requester: reviewer)
    context = ctx
    removed = context.emit("seat.removed", subject: builder)
    calls = recording_cancels do
      Leverage::SeatRuns.removed(context, builder, cause: removed)
      Leverage::SeatRuns.removed(context, reviewer, cause: removed)
    end

    assert_equal [ Cancelled.new(submit.id, "invalid_state", %w[seat.removed]),
                   Cancelled.new(pass.id, "invalid_state", %w[seat.removed task.released]) ], calls
  end

  test "release_working_task cancels a pending submit with invalid_state before task.released, and answers task.released" do
    builder = @scenario.seat(role: "builder")
    task = @scenario.task(state: "working", builder: builder)
    pending = @scenario.pending_transition(task, command: "submit", requester: builder)
    context = ctx
    released = nil
    calls = recording_cancels { released = Leverage::SeatRuns.release_working_task(context, builder, reason: "seat_disabled") }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", []) ], calls
    assert_equal "task.released", released.type
  end

  test "release_working_task cancels a provisional claim in Ready and answers nil: the withdrawal is all the task gets" do
    builder = @scenario.seat(role: "builder")
    task = @scenario.task(state: "ready")
    task.update!(holder_seat_id: builder.id)
    pending = @scenario.pending_transition(task, command: "claim", requester: builder)
    context = ctx
    released = :unset
    calls = recording_cancels { released = Leverage::SeatRuns.release_working_task(context, builder, reason: "seat_removed") }

    assert_equal [ Cancelled.new(pending.id, "invalid_state", []) ], calls
    assert_nil released
    assert_empty context.events
  end

  test "release_working_task cancels nothing for a seat that holds no pending transition, or whose lease has ended" do
    builder = @scenario.seat(role: "builder")
    @scenario.make_due(@scenario.task(state: "working", builder: builder))
    ended = @scenario.seat(role: "builder")
    @scenario.pending_transition(@scenario.make_due(@scenario.task(state: "working", builder: ended)),
      command: "submit", requester: ended)
    calls = recording_cancels do
      Leverage::SeatRuns.release_working_task(ctx, builder, reason: "seat_disabled")
      Leverage::SeatRuns.release_working_task(ctx, ended, reason: "seat_disabled")
    end

    assert_empty calls, "a lease past its due time is its timer's, which cancels what is pending"
  end
end
