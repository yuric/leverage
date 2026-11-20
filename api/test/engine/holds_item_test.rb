require "test_helper"

# The one seam milestone 3 found missing in Leverage::Holds (milestone 3
# plan §0.1 fact 5, rule 6 of §2.1, HE-4): Holds.open(item: false) opens a
# hold with no Needs you item, so a credential_limit hold that has a due
# time opens without "Limit with no reset time"; the default still opens
# the item the registry names. And the seat-bound close WP4 writes exists
# with its final arguments.
class HoldsItemTest < ActiveSupport::TestCase
  H = Leverage::Holds

  setup do
    @scenario = Scenario.new
    @credential = @scenario.limit_credential(@scenario.credential, reset_at: @scenario.database_now + 3600)
    @task = @scenario.task(state: "working", builder: @scenario.seat(credential: @credential))
  end

  def open(**options)
    ctx = @scenario.context
    hold = H.open(ctx, task: @task, reason: "credential_limit", credential_id: @credential.id, **options)
    [ hold, ctx.events.map(&:type) ]
  end

  test "item: false opens a credential_limit hold with no Needs you item and no inbox.opened" do
    hold, types = open(item: false)

    assert_equal [ "credential_limit", @credential.id ], [ hold.reason, hold.credential_id ]
    assert_equal [ "hold.opened" ], types
    refute InboxItem.exists?(hold_id: hold.id)
  end

  test "by default the hold opens the item the registry names, with inbox.opened" do
    hold, types = open

    assert_equal [ "hold.opened", "inbox.opened" ], types
    item = InboxItem.find_by!(hold_id: hold.id)
    assert_equal [ "limit_with_no_reset_time", @credential.id, "open" ], [ item.kind, item.credential_id, item.state ]
  end

  test "item: true is the default" do
    hold, types = open(item: true)

    assert_equal [ "hold.opened", "inbox.opened" ], types
    assert InboxItem.exists?(hold_id: hold.id)
  end

  test "a hold closed with no item writes no inbox.resolved" do
    hold, = open(item: false)
    ctx = @scenario.context
    H.close(ctx, hold: hold, task: @task)

    assert_equal [ "hold.closed" ], ctx.events.map(&:type)
  end

  test "close_seat_bound takes the context, the task, a cause and a wait_cause" do
    parameters = H.method(:close_seat_bound).parameters

    assert_equal [ [ :req, :ctx ], [ :req, :task ], [ :keyreq, :cause ], [ :keyreq, :wait_cause ] ], parameters
  end
end
