require "test_helper"
require_relative "entries/accounts_support"

# The two Credentials rows that store or schedule readings (CT-1).
class StateTableReadingsTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  StateTableCases.define(self, %w[report_reading usage_read_due]) do |kase|
    assert_nil kase.from
    assert_nil kase.to
    assert_nil kase.hook
    assert_nil kase.refusal
    assert_empty kase.conditional_events

    credential = scenario.credential
    request = request_for(kase.command, credential)
    caller = request.caller_kind || "app"
    assert_equal [ caller ], kase.who
    receipts = Command.where(workspace_id: scenario.workspace_id)
    count = receipts.count
    written = events_written { assert_completed(T.apply(request)) }
    assert_equal kase.events, written.map(&:type)

    if request.key
      assert_equal count + 1, receipts.count
      assert receipts.exists?(key: request.key, command: kase.command)
      assert_equal 1, CredentialReading.newest_for(credential).count
    else
      assert_equal count, receipts.count
      assert HelperRequest.exists?(workspace_id: scenario.workspace_id, credential_id: credential.id, kind: "read_usage")
    end
  end

  def request_for(command, credential)
    if command == "report_reading"
      helper_request(command, { "id" => credential.id, "credential_id" => credential.id,
        "observed_at" => scenario.database_now.utc.iso8601(6), "state" => "unavailable",
        "figures" => [], "resets" => nil, "tool_version" => nil })
    else
      scenario.live_helper
      T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: nil, caller_id: nil,
        key: nil, request_hash: nil, params: {})
    end
  end
end
