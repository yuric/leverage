require "test_helper"

# The handoff to WP9 (milestone 5 plan §4).
class WP9StubsTest < ActiveSupport::TestCase
  test "ContentDeletion.delete provides its handoff answer" do
    stub = "Leverage::ContentDeletion".safe_constantize
    assert stub, "Leverage::ContentDeletion is defined"
    assert_respond_to stub, :delete
    assert_nil stub.delete(nil, task: nil, project: nil)
  end

  test "Reads::WorkspaceSettings.call provides its handoff answer" do
    stub = "Leverage::Reads::WorkspaceSettings".safe_constantize
    assert stub, "Leverage::Reads::WorkspaceSettings is defined"
    assert_respond_to stub, :call
    assert_equal({}, stub.call(nil))
  end
end
