require "test_helper"
require_relative "accounts_support"

class RefreshUsageTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "refresh queues every added active login and token and preserves unfinished requests" do
    fresh_login = scenario.credential
    fresh_token = scenario.token_credential
    scenario.reading(fresh_login)
    scenario.reading(fresh_token)
    previous = scenario.helper_request(kind: "read_usage", credential: fresh_login, state: "finished")
    limited = scenario.limit_credential(scenario.credential)
    verify = scenario.helper_request(kind: "verify", credential: limited)
    queued = scenario.helper_request(kind: "read_usage", credential: scenario.credential)
    picked_up = scenario.helper_request(kind: "read_usage", credential: scenario.token_credential, state: "picked_up")
    scenario.credential(state: "signed_out")
    scenario.token_credential(state: "signed_out")
    scenario.credential(added: false, state: "active")
    Scenario.new.credential
    outcome = nil

    written = events_written { outcome = assert_completed(owner_command("refresh_usage")) }

    assert_empty written
    assert_equal [ "helper_request_ids" ], outcome.result&.keys
    ids = outcome.result.fetch("helper_request_ids")
    assert_equal 5, ids.size
    requests = HelperRequest.find(ids).index_by(&:credential_id)
    assert_equal [ fresh_login.id, fresh_token.id, limited.id, queued.credential_id, picked_up.credential_id ].sort,
      requests.keys.sort
    assert_equal [ queued.id, picked_up.id ], [ requests.fetch(queued.credential_id).id, requests.fetch(picked_up.credential_id).id ]
    assert_equal [ "queued", "picked_up" ], [ queued.reload.state, picked_up.reload.state ]
    assert_equal [ "finished", "queued" ], [ previous.reload.state, verify.reload.state ]
    [ fresh_login, fresh_token, limited ].each do |credential|
      request = requests.fetch(credential.id)
      assert_equal [ "read_usage", "queued", scenario.workspace_id ], [ request.kind, request.state, request.workspace_id ]
      assert_equal({ "provider" => credential.provider, "credential_kind" => credential.kind }, request.params)
    end
    assert_equal (ids + [ previous.id ]).sort, HelperRequest.where(kind: "read_usage").order(:id).pluck(:id)
  end

  test "repeating the same key answers the stored ids even after a request finishes" do
    scenario.credential
    key = new_key
    original = assert_completed(owner_command("refresh_usage", key: key))
    assert_equal [ "helper_request_ids" ], original.result&.keys
    request = HelperRequest.find(original.result.fetch("helper_request_ids").sole)
    request.update!(state: "finished", finished_at: scenario.database_now)

    written = events_written do
      assert_no_difference -> { HelperRequest.where(workspace_id: scenario.workspace_id, kind: "read_usage").count } do
        repeated = assert_completed(owner_command("refresh_usage", key: key))
        assert_equal original.result, repeated.result
      end
    end
    assert_empty written
  end
end
