require "test_helper"

# The handoff to WP11 (milestone 5 plan §4).
class WP11StubsTest < ActiveSupport::TestCase
  test "Reads::Decisions.call provides its handoff answer" do
    stub = "Leverage::Reads::Decisions".safe_constantize
    assert stub, "Leverage::Reads::Decisions is defined"
    assert_respond_to stub, :call
    assert_equal({ decisions: [] }, stub.call(nil))
  end

  test "Reads::Projects.call provides its handoff answer" do
    stub = "Leverage::Reads::Projects".safe_constantize
    assert stub, "Leverage::Reads::Projects is defined"
    assert_respond_to stub, :call
    assert_equal({ projects: [] }, stub.call(nil))
  end

  test "Reads::Question.call provides its handoff answer" do
    stub = "Leverage::Reads::Question".safe_constantize
    assert stub, "Leverage::Reads::Question is defined"
    assert_respond_to stub, :call
    assert_equal({}, stub.call(nil, nil))
  end
end
