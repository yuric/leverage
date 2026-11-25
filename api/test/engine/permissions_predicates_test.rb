require "test_helper"

# The three predicates every claim and lease path reads (contract decisions
# UX-10, UX-11a): a seat works when Work on tasks is on, builds when Work
# and Deliver are both on, and creates when Create tasks is on.
class PermissionsPredicatesTest < ActiveSupport::TestCase
  def perms = Leverage::Permissions

  setup { @scenario = Scenario.new }

  def seat(**permissions) = @scenario.seat(role: "general", **permissions)

  test "a new seat may do all three" do
    s = seat
    assert perms.works?(s)
    assert perms.builds?(s)
    assert perms.creates?(s)
  end

  test "Work off: no work, so no building either" do
    s = seat(may_work: false)
    refute perms.works?(s)
    refute perms.builds?(s)
    assert perms.creates?(s)
  end

  test "Deliver off: still works, never builds" do
    s = seat(may_deliver: false)
    assert perms.works?(s)
    refute perms.builds?(s)
  end

  test "Create off touches only creating" do
    s = seat(may_create: false)
    assert perms.works?(s)
    assert perms.builds?(s)
    refute perms.creates?(s)
  end

  test "the set as the interface writes it" do
    assert_equal({ "work" => true, "deliver" => false, "create" => true }, perms.to_h(seat(may_deliver: false)))
    assert_equal Leverage::Contract.list("seat_permissions"), perms.to_h(seat).keys
  end

  test "columns from an interface set, and the set a seat holds" do
    assert_equal({ may_work: false, may_deliver: true, may_create: true },
      perms.columns("work" => false, "deliver" => true, "create" => true))
  end
end
