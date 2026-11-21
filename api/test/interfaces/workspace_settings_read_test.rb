require "test_helper"

class WorkspaceSettingsReadTest < ActiveSupport::TestCase
  include OpenapiAssertions

  test "returns the requested workspace's six stored settings" do
    settings = {
      "lease_length_seconds" => 5100, "check_queue_timeout_seconds" => 95, "check_run_timeout_seconds" => 330,
      "maximum_rounds" => 6, "rerun_limit" => 9, "recovery_time_ceiling_seconds" => 1200
    }
    original = Scenario.new(**settings.symbolize_keys)
    other = Scenario.new
    read = Leverage::Reads::WorkspaceSettings

    result = read.call(original.workspace_id)
    assert_matches_component "WorkspaceSettings", result
    assert_equal settings, result

    defaults = read.call(other.workspace_id)
    assert_matches_component "WorkspaceSettings", defaults
    assert_equal({ "lease_length_seconds" => 3600, "check_queue_timeout_seconds" => 120, "check_run_timeout_seconds" => 300,
      "maximum_rounds" => 3, "rerun_limit" => 3, "recovery_time_ceiling_seconds" => nil }, defaults)
  end
end
