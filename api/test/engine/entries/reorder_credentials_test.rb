require "test_helper"
require_relative "handoff_support"
require_relative "call_spy"

class ReorderCredentialsTest < ActiveSupport::TestCase
  include HandoffSupport
  include CallSpy

  setup { use_scenario(lease_length_seconds: 3600) }

  test "reorder writes moved credentials first and closes a hold when a candidate becomes available" do
    available = scenario.credential
    token = scenario.token_credential
    first_pending = scenario.credential(added: false)
    second_pending = scenario.token_credential(added: false)
    own = scenario.credential
    seat = scenario.seat(credential: own)
    task = scenario.task(state: "working", builder: seat)
    scenario.sign_out_credential(own, seat: seat, task: task)
    hold = scenario.hold(task, reason: "credential_signed_out", credential: own, facts: { credential_id: own.id })
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_nil Leverage::Candidates.first_available(seat, task, from_now(0))

    key = new_key
    order = [ own, token, available ]
    before = Event.where(workspace_id: scenario.workspace_id).maximum(:at)
    written = nil
    handoffs = nil
    eligibility = spy_on(Leverage::ReviewerEligibility, :reevaluate) do
      handoffs = spy_on(Leverage::Handoff, :reevaluate) do
        written = events_written do
          with_clock(before - 0.040) { assert_completed(reorder(order, key: key)) }
        end
      end
    end

    assert_equal [
      [ "credential.order_changed", own.id ], [ "credential.order_changed", available.id ],
      [ "hold.closed", hold.id ], [ "credential.switched", available.id ], [ "inbox.resolved", item.id ]
    ], typed(written)
    assert_empty eligibility
    first, last, closed, switched, resolved = written
    assert_equal [ 1, 2, 3, 4, 5 ], (order + [ first_pending, second_pending ]).map { |credential| credential.reload.position }
    assert_equal [ last.id, closed.id ], [ closed.cause_id, switched.cause_id ]
    assert_equal last.id, handoffs.sole.keywords.fetch(:cause).id
    assert_equal [ key ] * written.size, written.map(&:command_id)
    assert_operator first.at, :>, before
    assert_equal [ [ "owner", scenario.owner.id ] ] * 2, [ first, last ].map { |event| [ event.actor_kind, event.actor_id ] }
    assert_equal [ {}, {} ], [ first.payload, last.payload ]
    assert_equal [ [ "owner", scenario.owner.id ], [ "app", nil ], [ "owner", scenario.owner.id ] ],
      [ closed, switched, resolved ].map { |event| [ event.actor_kind, event.actor_id ] }
    assert_equal [ task.id ] * 3, [ closed, switched, resolved ].map(&:task_id)
    assert hold.reload.closed_at
    assert_equal "resolved", item.reload.state
    assert_equal available.id, task.reload.credential_id
  end

  test "reorder that loses the only reset time opens an item beside the existing limit hold" do
    own = scenario.credential
    dated = scenario.credential
    seat = scenario.seat(credential: own)
    task = scenario.task(state: "working", builder: seat)
    scenario.limit_credential(own)
    scenario.limit_credential(dated, reset_at: from_now(1800))
    hold = scenario.hold(task, reason: "credential_limit", credential: dated, item: false)
    assert_equal dated.limited_until, Leverage::Candidates.due_at(seat, task, from_now(0))

    key = new_key
    written = events_written { assert_completed(reorder([ dated, own ], key: key)) }

    assert_equal %w[credential.order_changed credential.order_changed inbox.opened], written.map(&:type)
    item = InboxItem.where(hold_id: hold.id, state: "open").sole
    opened = written.last
    assert_equal [ "limit_with_no_reset_time", own.id ], [ item.kind, item.credential_id ]
    assert_equal [ item.id, task.id, written[1].id, "owner", scenario.owner.id, key ],
      [ opened.subject_id, opened.task_id, opened.cause_id, opened.actor_kind, opened.actor_id, opened.command_id ]
    assert_equal [ "credential_limit", dated.id, nil ], hold.reload.attributes.values_at("reason", "credential_id", "closed_at")
    assert_nil Leverage::Candidates.due_at(seat, task, from_now(0))
  end

  test "events follow rank changes among added credentials even when a removal leaves a gap" do
    first, removed, second, third = Array.new(4) { scenario.credential }
    assert_completed owner_command("remove_credential", { "id" => removed.id })
    written = events_written { assert_completed reorder([ third, second, first ]) }

    assert_equal [ [ "credential.order_changed", third.id ], [ "credential.order_changed", first.id ] ], typed(written)
    assert_equal [ 1, 2, 3 ], [ third, second, first ].map { |credential| credential.reload.position }
  end

  test "a credential whose rank moves gets an event even if its stored position stays the same" do
    removed, first, second = Array.new(3) { scenario.credential }
    assert_completed owner_command("remove_credential", { "id" => removed.id })

    written = events_written { assert_completed reorder([ second, first ]) }

    assert_equal [ second.id, first.id ], written.map(&:subject_id)
    assert_equal 2, first.reload.position
  end

  test "an equal order writes no event and does not reconsider holds" do
    own = scenario.credential
    token = scenario.token_credential

    handoffs = spy_on(Leverage::Handoff, :reevaluate) do
      assert_empty events_written { assert_completed(reorder([ own, token ])) }
    end
    assert_empty handoffs
    assert_equal [ 1, 2 ], [ own.reload.position, token.reload.position ]
  end

  test "a list other than the entire added set is invalid and changes nothing" do
    login = scenario.credential
    token = scenario.token_credential
    pending = scenario.credential(added: false)
    foreign = Scenario.new.credential
    unknown = SecureRandom.uuid

    handoffs = spy_on(Leverage::Handoff, :reevaluate) do
      written = events_written do
        [
          nil, "not an order", [], [ login.id ], [ token.id, token.id ], [ token.id, login.id, token.id ],
          [ token.id, unknown ], [ token.id, foreign.id ], [ token.id, pending.id ],
          [ token.id, login.id, pending.id ]
        ].each do |ids|
          assert_raises(T::Invalid, "order #{ids.inspect}") do
            owner_command("reorder_credentials", { "order" => ids })
          end
        end
      end
      assert_empty written
    end
    assert_empty handoffs
    assert_equal [ 1, 2, 3, 1 ], [ login, token, pending, foreign ].map { |credential| credential.reload.position }
  end

  test "repeating the same key does not apply the old order after a newer reorder" do
    first = scenario.credential
    second = scenario.token_credential
    key = new_key
    written = events_written { assert_completed(reorder([ second, first ], key: key)) }
    assert_equal [ second.id, first.id ], written.map(&:subject_id)
    assert_completed(reorder([ first, second ]))

    handoffs = spy_on(Leverage::Handoff, :reevaluate) do
      assert_empty events_written { assert_completed(reorder([ second, first ], key: key)) }
    end
    assert_empty handoffs
    assert_equal [ 1, 2 ], [ first.reload.position, second.reload.position ]
  end

  private

  def reorder(credentials, **options)
    owner_command("reorder_credentials", { "order" => credentials.map(&:id) }, **options)
  end

  def with_clock(reading)
    lock = Leverage::WorkspaceLock
    original = lock.method(:clock)
    lock.define_singleton_method(:clock) { reading }
    yield
  ensure
    lock.define_singleton_method(:clock, original)
  end
end
