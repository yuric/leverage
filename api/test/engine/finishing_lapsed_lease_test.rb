require "test_helper"

# A General builder whose lease on one task is past due, and not yet ended
# by its timer, while another task it built waits in Finishing for it: the
# seat is not free for the waiting task's lease until the lapsed lease has
# ended. One seat holds one task (the unique index on tasks.holder_seat_id),
# so a grant before then would fail every command in the workspace.
class FinishingLapsedLeaseTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @general = @scenario.seat(role: "general")
    @waiting = @scenario.finishing_task(builder: @general, holder: false, actions: [ { kind: "send", state: "approved" } ])
  end

  # The task the seat works on, its lease a minute past due.
  def lapse
    @lapsed = @scenario.task(state: "working", builder: @general)
    @scenario.make_due(@lapsed, at: @scenario.database_now - 60)
  end

  test "a command that names neither task completes and leaves the waiting task waiting" do
    other = @scenario.task(state: "ready")
    lapse

    assert owner("change_task_priority", other, "priority" => "high").completed?

    assert_nil @waiting.reload.holder_seat_id
    assert_equal [ "working", @general.id ], @lapsed.reload.attributes.values_at("state", "holder_seat_id")
  end

  test "approving another waiting task's action completes without a lease" do
    second = @scenario.finishing_task(builder: @general, holder: false, actions: [ { kind: "send", state: "requested" } ])
    action = Action.find_by!(task_id: second.id)
    Leverage::Finishing.open_owner_approval(@scenario.context, action)
    lapse

    assert owner("approve_action", action).completed?

    assert_equal "approved", action.reload.state
    assert_nil second.reload.holder_seat_id
  end

  test "the sweep ends the lapsed lease after a due job timer, then the waiting task gets its lease" do
    drafted = @scenario.task(state: "backlog")
    job = @scenario.job(kind: "contract_draft", task: drafted)
    job.update_columns(queued_at: @scenario.database_now - 30.days)
    lapse

    Leverage::Sweep.sweep_workspace(@scenario.workspace_id)

    assert_equal "timed_out", job.reload.state
    assert_equal [ "ready", nil ], @lapsed.reload.attributes.values_at("state", "holder_seat_id")
    assert_equal @general.id, @waiting.reload.holder_seat_id
  end

  test "another seat's claim ends two due leases, the other builder's first, and completes" do
    other_builder = @scenario.seat(role: "builder")
    earlier = @scenario.task(state: "working", builder: other_builder)
    @scenario.make_due(earlier, at: @scenario.database_now - 120)
    @scenario.task(state: "ready")
    claimer = @scenario.seat(role: "builder")
    lapse

    assert seat("claim", claimer).completed?

    assert_equal "ready", @lapsed.reload.state
    assert_equal @general.id, @waiting.reload.holder_seat_id
  end

  private

  def owner(command, target, params = {})
    apply(command, "owner", @scenario.owner, params.merge("id" => target.id))
  end

  def seat(command, caller, params = {})
    apply(command, "seat", caller, params)
  end

  def apply(command, kind, caller, params)
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id,
      caller_kind: kind, caller_id: caller.id, key: SecureRandom.uuid,
      request_hash: Digest::SHA256.hexdigest(params.to_json), params: params))
  end
end
