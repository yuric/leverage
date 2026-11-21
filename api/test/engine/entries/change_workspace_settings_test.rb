require "test_helper"
require_relative "accounts_support"

class ChangeWorkspaceSettingsTest < ActiveSupport::TestCase
  include AccountsSupport
  include OpenapiAssertions

  BOUNDS = {
    "lease_length_seconds" => [ 300, 86_400 ],
    "check_queue_timeout_seconds" => [ 30, 3600 ],
    "check_run_timeout_seconds" => [ 60, 3600 ],
    "maximum_rounds" => [ 1, 20 ],
    "rerun_limit" => [ 1, 20 ],
    "recovery_time_ceiling_seconds" => [ 60, 86_400 ]
  }.freeze

  setup { use_scenario }

  BOUNDS.each do |field, (minimum, maximum)|
    test "accepts both bounds of #{field}" do
      [ minimum, maximum ].each do |value|
        result = change({ field => value }).result
        assert_matches_component "WorkspaceSettings", result
        assert_equal value, result.fetch(field)
        assert_equal value, scenario.workspace.reload[field]
      end
    end

    test "refuses values outside the bounds of #{field} without a partial write" do
      unchanged = settings
      [ minimum - 1, maximum + 1, minimum.to_s, minimum + 0.5 ].each do |value|
        body = { "lease_length_seconds" => 600, "maximum_rounds" => 2, field => value }
        assert_raises(Leverage::Transitions::Invalid) { owner_command("change_workspace_settings", body) }
        assert_equal unchanged, settings
      end
    end
  end

  test "empty object completes with current settings and writes one empty workspace event" do
    before = settings
    key = new_key
    written = events_written do
      assert_equal before, change({}, key: key).result
    end
    assert_equal [ "workspace.settings_changed" ], written.map(&:type)
    event = written.first
    assert_equal [ nil, nil, nil, nil, nil, "owner", scenario.owner.id, key, {} ],
      [ event.project_id, event.task_id, event.round, event.subject_kind, event.subject_id,
        event.actor_kind, event.actor_id, event.command_id, event.payload ]
    assert_equal before, settings
  end

  test "omitting the ceiling preserves it and explicit null clears it" do
    field = "recovery_time_ceiling_seconds"
    assert_equal 600, change({ field => 600 }).result.fetch(field)
    assert_equal 600, change({ "maximum_rounds" => 4 }).result.fetch(field)
    assert_nil change({ field => nil }).result.fetch(field)
    assert_nil scenario.workspace.reload[field]
  end

  test "rejects null for each required integer and refuses extra fields" do
    (BOUNDS.keys - [ "recovery_time_ceiling_seconds" ]).each do |field|
      assert_raises(Leverage::Transitions::Invalid) { owner_command("change_workspace_settings", { field => nil }) }
    end
    assert_raises(Leverage::Transitions::Invalid) { owner_command("change_workspace_settings", { "last_seq" => 99 }) }
  end

  private

  def settings = scenario.workspace.reload.attributes.slice(*BOUNDS.keys)

  def change(body, **options)
    outcome = assert_completed owner_command("change_workspace_settings", body, **options)
    assert_kind_of Hash, outcome.result
    outcome
  end
end
