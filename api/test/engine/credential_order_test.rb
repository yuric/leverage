require "test_helper"

class CredentialOrderTest < ActiveSupport::TestCase
  setup do
    @scenario = Scenario.new
    @order = Leverage::CredentialOrder.new(@scenario.workspace_id)
  end

  test "a newly added login goes above the first token and shifts every following row" do
    first = @scenario.credential
    token = @scenario.token_credential
    later = @scenario.credential
    second_token = @scenario.token_credential
    arriving = @scenario.credential(added: false)
    arriving.update!(last_verified_at: @scenario.database_now, state: "active")
    unfinished = @scenario.credential(added: false)
    assert_no_difference -> { Event.where(workspace_id: @scenario.workspace_id).count } do
      @order.place(arriving)
    end

    assert_equal [ 1, 2, 3, 4, 5, 7 ], [ first, arriving, token, later, second_token, unfinished ].map { |row| row.reload.position }
  end

  test "a newly added token goes last even if its checks finish before those of a later Add" do
    first = @scenario.credential
    arriving = @scenario.token_credential(added: false)
    later = @scenario.credential
    arriving.update!(last_verified_at: @scenario.database_now, state: "active")

    @order.place(arriving)

    assert_operator arriving.reload.position, :>, later.reload.position
    assert_operator later.position, :>, first.reload.position
  end

  test "a newly added login goes last when there are no added tokens" do
    @scenario.credential
    arriving = @scenario.credential(added: false)
    @scenario.token_credential(added: false)
    later = @scenario.credential

    @order.place(arriving)

    assert_operator arriving.reload.position, :>, later.reload.position
  end

  test "only the entire added set, in any order, passes validation" do
    first = @scenario.credential
    second = @scenario.token_credential
    pending = @scenario.credential(added: false)
    foreign = Scenario.new.credential

    assert @order.exactly_the_added?([ second.id, first.id ])
    refute @order.exactly_the_added?([ first.id ])
    refute @order.exactly_the_added?([ first.id, first.id ])
    refute @order.exactly_the_added?([ first.id, SecureRandom.uuid ])
    refute @order.exactly_the_added?([ first.id, foreign.id ])
    refute @order.exactly_the_added?([ first.id, second.id, pending.id ])
  end

  test "an empty workspace has an empty added set" do
    @scenario.credential(added: false)
    assert @order.exactly_the_added?([])
  end

  test "an identical order writes nothing, including after a removal leaves a gap" do
    first = @scenario.credential
    missing = @scenario.credential
    last = @scenario.token_credential
    missing.delete
    prior_positions = [ first.position, last.position ]

    assert_empty @order.apply([ first.id, last.id ])
    assert_equal prior_positions, [ first.reload.position, last.reload.position ]
  end

  test "a different order writes consecutive positions and returns only moved added credentials in new order" do
    first = @scenario.credential
    middle = @scenario.token_credential
    pending_first = @scenario.credential(added: false)
    pending_second = @scenario.token_credential(added: false)
    last = @scenario.credential
    foreign = Scenario.new.credential

    assert_no_difference -> { Event.where(workspace_id: @scenario.workspace_id).count } do
      assert_equal [ last.id, first.id ], @order.apply([ last.id, middle.id, first.id ]).map(&:id)
    end
    assert_equal [ 1, 2, 3, 4, 5 ], [ last, middle, first, pending_first, pending_second ].map { |row| row.reload.position }
    assert_equal 1, foreign.reload.position
  end
end
