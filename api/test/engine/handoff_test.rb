require "test_helper"
require_relative "entries/handoff_support"

# Leverage::Handoff.reevaluate (PRD L694-L699; milestone 3 plan §2.1 rule 7,
# HE-2, HE-10, HE-11, HE-29; traces 12 and 14): the commands that can make a
# candidate available (a verified or added login, a changed seat) look again
# at the open credential holds, oldest first in bounded batches. A hold
# whose holder now has an available candidate closes: hold.closed (caused
# by the change), credential.switched when the first available candidate is
# not the credential recorded, inbox.resolved, and a start on it. An
# "Account signed out" item is resolved when its account is verified,
# whether or not the hold can close. A command that writes
# credential.signed_out asks only for HE-11's item, and closes nothing.
#
# The calls are made as report_request_result (WP5) and change_seat (WP6)
# make them, inside a command of the helper.
class HandoffTest < ActiveSupport::TestCase
  include HandoffSupport

  H = Leverage::Handoff

  setup do
    use_scenario(lease_length_seconds: 3600)
  end

  # Runs the block inside a command of the helper, with its context.
  def as_helper(command = "report_request_result")
    ActiveRecord::Base.transaction(requires_new: true) do
      yield scenario.context(request: helper_request(command, {}))
    end
  end

  # A reorder's context, with only the two changed positions written.
  # The entry's validation and its call to reevaluate are tested separately.
  def after_swapping_positions(first, second)
    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = scenario.context(request: owner_request("reorder_credentials"))
      first_position = first.position
      first.update!(position: second.position)
      second.update!(position: first_position)
      ctx.emit("credential.order_changed", subject: second, payload: {})
      cause = ctx.emit("credential.order_changed", subject: first, payload: {})
      H.reevaluate(ctx, cause: cause)
    end
  end

  # A login just verified inside the command: active, signed in, no limit
  # with no reset time (HE-2, which report_request_result writes), and its
  # credential.verified.
  def verify(ctx, credential)
    credential.update!(state: "active", last_verified_at: ctx.at)
    credential.update!(limited_since: nil) if credential.limited_until.nil?
    ctx.emit("credential.verified", subject: credential, payload: {})
  end

  # Trace 12's hold: the builder's own login found signed out, a second
  # Claude login signed out too, the task held credential_signed_out with
  # its item.
  def trace_12
    scenario.credential(provider: "codex")
    @claude_a = scenario.credential(provider: "claude", model: "claude-model-1")
    @claude_b = scenario.sign_out_credential(scenario.credential(provider: "claude", model: "claude-model-1"))
    @builder = scenario.seat(role: "builder", credential: @claude_a, model: "claude-model-1")
    @task = scenario.task(state: "working", builder: @builder)
    scenario.sign_out_credential(@claude_a, seat: @builder, task: @task)
    @hold = scenario.hold(@task, reason: "credential_signed_out", credential: @claude_a,
      facts: { credential_id: @claude_a.id })
    @item = InboxItem.find_by!(hold_id: @hold.id)
  end

  test "trace 12: a login verified by Sign in again closes the hold, switches to it and resolves the item" do
    trace_12
    written = nil
    ensured = runs_ensured do
      written = events_written do
        as_helper do |ctx|
          verified = verify(ctx, @claude_b)
          H.reevaluate(ctx, verified: @claude_b, cause: verified, choice: "sign_in_again")
        end
      end
    end

    verified, closed, switched, resolved = written
    assert_equal %w[credential.verified hold.closed credential.switched inbox.resolved], written.map(&:type)
    assert_equal [ @hold.id, verified.id, "app", scenario.helper.id ],
      [ closed.subject_id, closed.cause_id, closed.actor_kind, closed.actor_id ]
    assert_equal({ "reason" => "credential_signed_out", "rule_id" => nil, "credential_id" => @claude_a.id,
                   "lease_seat_id" => nil, "wait_cause" => nil }, closed.payload)
    assert_equal [ @claude_b.id, closed.id, { "from_credential_id" => @claude_a.id, "model" => "claude-model-1",
                                              "seat_id" => @builder.id, "review_id" => nil, "job_id" => nil } ],
      [ switched.subject_id, switched.cause_id, switched.payload ]
    assert_equal [ @item.id, nil, { "choice" => "sign_in_again" } ],
      [ resolved.subject_id, resolved.cause_id, resolved.payload ]
    assert_equal [ "resolved", "app", scenario.helper.id ], @item.reload.attributes.values_at("state", "resolved_by_kind", "resolved_by_id")
    assert @hold.reload.closed_at
    @task.reload
    assert_equal @claude_b.id, @task.credential_id
    assert @task.lease_due_at, "credential_signed_out paused the lease; it runs again"
    assert @task.resume_pending_since, "the seat is told to resume"
    assert_equal [ [ @builder.id, @claude_b.id, [ "Task", @task.id ] ] ], ensured
  end

  test "trace 14: a passed Verify of a login limited with no reset time closes its hold with no switch and no choice (HE-2)" do
    grok_z = scenario.credential(provider: "grok")
    scenario.limit_credential(scenario.credential(provider: "codex"))
    builder = scenario.seat(role: "builder", credential: grok_z)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(grok_z)
    hold = scenario.hold(task, reason: "credential_limit", credential: grok_z, facts: { credential_id: grok_z.id })

    written = events_written do
      as_helper do |ctx|
        H.reevaluate(ctx, verified: grok_z, cause: verify(ctx, grok_z), choice: "sign_in_again")
      end
    end

    assert_equal %w[credential.verified hold.closed inbox.resolved], written.map(&:type)
    assert_equal({ "choice" => nil }, written.last.payload, "HE-29: sign_in_again is not one of this item's choices")
    assert hold.reload.closed_at
  end

  test "trace 14: Sign in again of the login an Account signed out item names resolves it while the hold waits for a reset (HE-11)" do
    grok_z = scenario.credential(provider: "grok")
    scenario.limit_credential(scenario.credential(provider: "codex"))
    builder = scenario.seat(role: "builder", credential: grok_z)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(grok_z, reset_at: from_now(6000))
    hold = scenario.hold(task, reason: "credential_limit", credential: grok_z, item: false)
    signed_out = scenario.sign_out_credential(grok_z) && Event.where(subject_id: grok_z.id, type: "credential.signed_out").sole

    opened = events_written { as_helper { |ctx| H.reevaluate(ctx, signed_out: grok_z, cause: signed_out) } }
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_equal [ [ "inbox.opened", item.id ] ], typed(opened)
    assert_equal [ signed_out.id, task.id ], [ opened.first.cause_id, opened.first.task_id ]

    resolved = events_written do
      as_helper { |ctx| H.reevaluate(ctx, verified: grok_z, cause: verify(ctx, grok_z), choice: "sign_in_again") }
    end
    assert_equal [ [ "credential.verified", grok_z.id ], [ "inbox.resolved", item.id ] ], typed(resolved)
    assert_equal({ "choice" => "sign_in_again" }, resolved.last.payload)
    assert_nil hold.reload.closed_at, "the hold waits for the reset (L661)"
    assert_equal "resolved", item.reload.state
  end

  test "a sign-out reevaluation closes nothing, even when a hold could close (HE-10, HE-11)" do
    trace_12
    @claude_b.update!(state: "active", last_verified_at: from_now(0))
    codex = scenario.credential(provider: "codex")

    written = events_written { as_helper { |ctx| H.reevaluate(ctx, signed_out: codex, cause: nil) } }

    assert_empty written
    assert_nil @hold.reload.closed_at
  end

  test "an Account signed out item opens only for a credential_limit hold whose seat has the login as a candidate" do
    grok_z = scenario.credential(provider: "grok")
    builder = scenario.seat(role: "builder", credential: grok_z)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(grok_z)
    hold = scenario.hold(task, reason: "credential_limit", credential: grok_z, item: false)
    stranger = scenario.credential(provider: "claude")
    stranger.update_columns(position: 0)
    scenario.sign_out_credential(stranger)

    written = events_written { as_helper { |ctx| H.reevaluate(ctx, signed_out: stranger) } }

    assert_empty written
    assert_empty InboxItem.where(hold_id: hold.id)
  end

  # Review: a credential_signed_out hold that names a login rule 3 passes
  # over for the task (as the hold of a version before the review could
  # open). Once that login is signed in again its item is resolved, and
  # the hold, with no due time, would wait with nothing for the owner to
  # do: the item for what still blocks it opens instead.
  test "a hold left with no item and no due time after Sign in again gets the item for what still blocks it (review)" do
    claude = scenario.credential(provider: "claude", model: "claude-model-1", strength_rank: 3)
    codex = scenario.sign_out_credential(scenario.credential(provider: "codex", strength_rank: 1))
    builder = scenario.seat(role: "builder", credential: claude, strength_rank: 3)
    task = scenario.task(state: "working", builder: builder)
    task.update_columns(minimum_strength_rank: 3)
    scenario.limit_credential(claude, seat: builder, task: task, window: "weekly")
    hold = scenario.hold(task, reason: "credential_signed_out", credential: codex, facts: { credential_id: codex.id })
    item = InboxItem.find_by!(hold_id: hold.id)

    written = events_written do
      as_helper { |ctx| H.reevaluate(ctx, verified: codex, cause: verify(ctx, codex), choice: "sign_in_again") }
    end

    assert_equal %w[credential.verified inbox.resolved inbox.opened], written.map(&:type)
    assert_equal "resolved", item.reload.state
    assert_nil hold.reload.closed_at
    opened = InboxItem.find_by!(hold_id: hold.id, state: "open")
    assert_equal [ "limit_with_no_reset_time", claude.id, { "credential_id" => claude.id } ],
      [ opened.kind, opened.credential_id, opened.facts ]
    assert_equal [ opened.id, task.id ], [ written.last.subject_id, written.last.task_id ]
  end

  test "an Account signed out item does not open for a login rule 3 passes over for the held task (review)" do
    grok_z = scenario.credential(provider: "grok", strength_rank: 3)
    weak = scenario.credential(provider: "codex", strength_rank: 1)
    builder = scenario.seat(role: "builder", credential: grok_z, strength_rank: 3)
    task = scenario.task(state: "working", builder: builder)
    task.update_columns(minimum_strength_rank: 3)
    scenario.limit_credential(grok_z)
    hold = scenario.hold(task, reason: "credential_limit", credential: grok_z, item: false)
    scenario.sign_out_credential(weak)

    written = events_written { as_helper { |ctx| H.reevaluate(ctx, signed_out: weak) } }

    assert_empty written
    assert_empty InboxItem.where(hold_id: hold.id)
  end

  test "tasks: limits the look to those tasks" do
    trace_12
    @claude_b.update!(state: "active", last_verified_at: from_now(0))
    ready = scenario.task(state: "ready")
    written = events_written { as_helper { |ctx| H.reevaluate(ctx, tasks: [ ready ]) } }

    assert_empty written
    assert_nil @hold.reload.closed_at
  end

  test "a reorder that removes the only reset opens a no-reset item for the first candidate" do
    first = scenario.credential(provider: "claude")
    dated = scenario.credential(provider: "codex")
    later = scenario.credential(provider: "grok")
    builder = scenario.seat(role: "builder", credential: first)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(first)
    scenario.limit_credential(dated, reset_at: from_now(6000))
    scenario.limit_credential(later)
    hold = scenario.hold(task, reason: "credential_limit", credential: dated, item: false)

    written = events_written { after_swapping_positions(first, dated) }

    assert_equal %w[credential.order_changed credential.order_changed inbox.opened], written.map(&:type)
    item = InboxItem.find_by!(hold_id: hold.id, state: "open")
    assert_equal [ "limit_with_no_reset_time", first.id, { "credential_id" => first.id } ],
      [ item.kind, item.credential_id, item.facts ]
    assert_equal [ item.id, task.id, written[1].id ], [ written.last.subject_id, written.last.task_id, written.last.cause_id ]
    assert_equal [ "credential_limit", dated.id, nil ], hold.reload.attributes.values_at("reason", "credential_id", "closed_at")

    second_look = events_written do
      ActiveRecord::Base.transaction(requires_new: true) do
        H.reevaluate(scenario.context(request: owner_request("reorder_credentials")))
      end
    end

    assert_empty second_look
    assert_equal [ item.id ], InboxItem.where(hold_id: hold.id, state: "open").pluck(:id)
  end

  test "a reorder with no reset prefers the first signed-out candidate to an earlier limited candidate" do
    own = scenario.credential(provider: "claude")
    dated = scenario.credential(provider: "codex")
    first_signed_out = scenario.credential(provider: "grok")
    later_signed_out = scenario.credential(provider: "claude")
    builder = scenario.seat(role: "builder", credential: own)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(own)
    scenario.limit_credential(dated, reset_at: from_now(6000))
    hold = scenario.hold(task, reason: "credential_limit", credential: dated, item: false)
    scenario.sign_out_credential(first_signed_out)
    scenario.sign_out_credential(later_signed_out)

    written = events_written { after_swapping_positions(own, dated) }

    assert_equal %w[credential.order_changed credential.order_changed inbox.opened], written.map(&:type)
    item = InboxItem.find_by!(hold_id: hold.id, state: "open")
    assert_equal [ "account_signed_out", first_signed_out.id, { "credential_id" => first_signed_out.id } ],
      [ item.kind, item.credential_id, item.facts ]
    assert_equal [ "credential_limit", nil ], hold.reload.attributes.values_at("reason", "closed_at")
  end

  test "a reorder writes no inbox item while a credential limit hold still has a due time" do
    own = scenario.credential(provider: "claude")
    dated = scenario.credential(provider: "codex")
    spare = scenario.credential(provider: "grok")
    builder = scenario.seat(role: "builder", credential: own)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(own)
    scenario.limit_credential(dated, reset_at: from_now(6000))
    scenario.limit_credential(spare)
    hold = scenario.hold(task, reason: "credential_limit", credential: dated, item: false)

    written = events_written { after_swapping_positions(dated, spare) }

    assert_equal %w[credential.order_changed credential.order_changed], written.map(&:type)
    assert_empty InboxItem.where(hold_id: hold.id)
    assert_nil hold.reload.closed_at
  end

  test "removing an unrecorded candidate with the only reset also opens the no-reset item" do
    own = scenario.credential
    dated = scenario.credential
    builder = scenario.seat(credential: own)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(own)
    scenario.limit_credential(dated, reset_at: from_now(6000))
    hold = scenario.hold(task, reason: "credential_limit", credential: own, item: false)

    written = events_written do
      Credential.transaction do
        ctx = scenario.context(request: owner_request("remove_credential"))
        cause = ctx.emit("credential.removed", subject: dated, payload: {})
        dated.delete
        H.reevaluate(ctx, cause: cause)
      end
    end

    assert_equal %w[credential.removed inbox.opened], written.map(&:type)
    item = InboxItem.find_by!(hold_id: hold.id, state: "open")
    assert_equal [ "limit_with_no_reset_time", own.id, written.first.id ],
      [ item.kind, item.credential_id, written.last.cause_id ]
    assert_nil hold.reload.closed_at
  end

  test "a reorder that restores a due time resolves the no-reset item under a clock that steps back" do
    dated = scenario.credential(provider: "codex")
    own = scenario.credential(provider: "claude")
    builder = scenario.seat(role: "builder", credential: own)
    task = scenario.task(state: "working", builder: builder)
    scenario.limit_credential(dated, reset_at: from_now(6000))
    scenario.limit_credential(own)
    hold = scenario.hold(task, reason: "credential_limit", credential: own, facts: { credential_id: own.id })
    item = InboxItem.find_by!(hold_id: hold.id)
    before = Event.where(workspace_id: scenario.workspace_id).order(:seq).last
    lock = Leverage::WorkspaceLock
    original = lock.method(:clock)
    lock.define_singleton_method(:clock) { before.at - 1 }

    written = events_written { after_swapping_positions(dated, own) }

    assert_equal %w[credential.order_changed credential.order_changed inbox.resolved], written.map(&:type)
    resolved = written.last
    assert_equal [ item.id, task.id, { "choice" => nil } ], [ resolved.subject_id, resolved.task_id, resolved.payload ]
    assert_equal [ "resolved", "owner", scenario.owner.id, resolved.at ],
      item.reload.attributes.values_at("state", "resolved_by_kind", "resolved_by_id", "resolved_at")
    assert_equal before.at + Rational(1, 1_000_000), resolved.at
    assert_operator resolved.effective_at, :>=, before.effective_at
    assert_equal [ "credential_limit", own.id, nil ], hold.reload.attributes.values_at("reason", "credential_id", "closed_at")
  ensure
    lock.define_singleton_method(:clock, original) if original
  end

  test "the open credential holds are looked at oldest first, in bounded batches" do
    codex = scenario.credential(provider: "codex")
    seats = Array.new(3) { scenario.seat(role: "builder", credential: codex) }
    tasks = seats.map { |seat| scenario.task(state: "working", builder: seat) }
    scenario.limit_credential(codex)
    holds = tasks.map { |task| scenario.hold(task, reason: "credential_limit", credential: codex, item: false) }
    codex.update!(limited_since: nil)

    saved = H::BATCH
    H.send(:remove_const, :BATCH)
    H.const_set(:BATCH, 1)
    written = events_written { as_helper { |ctx| H.reevaluate(ctx) } }

    assert_equal holds.map(&:id), written.select { |event| event.type == "hold.closed" }.map(&:subject_id)
    assert(holds.all? { |hold| hold.reload.closed_at })
  ensure
    if saved
      H.send(:remove_const, :BATCH)
      H.const_set(:BATCH, saved)
    end
  end
end
