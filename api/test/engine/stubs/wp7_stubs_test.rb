require "test_helper"

# The handoff to WP7 (milestone 5 plan §4).
class WP7StubsTest < ActiveSupport::TestCase
  test "Projects.create provides its handoff answer" do
    stub = "Leverage::Projects".safe_constantize
    assert stub, "Leverage::Projects is defined"
    assert_respond_to stub, :create
    assert_nil stub.create(nil, name: nil, goal: nil, budget: nil)
  end

  test "Projects.edit_brief provides its handoff answer" do
    stub = "Leverage::Projects".safe_constantize
    assert stub, "Leverage::Projects is defined"
    assert_respond_to stub, :edit_brief
    assert_nil stub.edit_brief(nil, nil, entries: nil)
  end

  test "Projects.pause provides its handoff answer" do
    stub = "Leverage::Projects".safe_constantize
    assert stub, "Leverage::Projects is defined"
    assert_respond_to stub, :pause
    assert_nil stub.pause(nil, nil, by: nil)
  end

  test "Projects.resume provides its handoff answer" do
    stub = "Leverage::Projects".safe_constantize
    assert stub, "Leverage::Projects is defined"
    assert_respond_to stub, :resume
    assert_nil stub.resume(nil, nil)
  end

  test "Projects.change_budget provides its handoff answer" do
    stub = "Leverage::Projects".safe_constantize
    assert stub, "Leverage::Projects is defined"
    assert_respond_to stub, :change_budget
    assert_nil stub.change_budget(nil, nil, budget: nil)
  end

  test "Projects.hold_if_paused provides its handoff answer" do
    stub = "Leverage::Projects".safe_constantize
    assert stub, "Leverage::Projects is defined"
    assert_respond_to stub, :hold_if_paused
    assert_nil stub.hold_if_paused(nil, nil)
  end

  test "Projects.release_from provides its handoff answer" do
    stub = "Leverage::Projects".safe_constantize
    assert stub, "Leverage::Projects is defined"
    assert_respond_to stub, :release_from
    assert_nil stub.release_from(nil, nil, nil)
  end
end
