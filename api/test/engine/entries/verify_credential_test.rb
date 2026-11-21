require "test_helper"
require_relative "accounts_support"

# verify_credential (PRD L613; milestone 2 plan IN-23, IN-25): queues a
# verify request for an added credential and writes no event; the helper's
# report writes the outcome.
class VerifyCredentialTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "it queues a verify request with the provider and kind, and writes no event" do
    credential = @scenario.credential(provider: "codex", name: "Made-up verified name")
    written = events_written do
      @outcome = assert_completed(owner_command("verify_credential", { "id" => credential.id }))
    end

    assert_empty written
    request = HelperRequest.find(@outcome.result.fetch("helper_request_id"))
    assert_equal [ "verify", "queued", credential.id, nil ], [ request.kind, request.state, request.credential_id, request.seat_id ]
    assert_equal({ "provider" => "codex", "credential_kind" => "login" }, request.params)
    assert_not_includes request.attributes.to_json, "Made-up verified name"
    assert_equal [ "helper_request_id" ], @outcome.result.keys
  end

  test "a signed-out credential can be verified" do
    credential = @scenario.credential(state: "signed_out")

    assert_completed(owner_command("verify_credential", { "id" => credential.id }))
  end

  test "a credential whose add still runs is not found: it is not an added credential yet" do
    credential = @scenario.credential(added: false)

    assert_raises(T::NotFound) { owner_command("verify_credential", { "id" => credential.id }) }
  end

  test "a credential of another workspace is not found" do
    credential = Scenario.new.credential

    assert_raises(T::NotFound) { owner_command("verify_credential", { "id" => credential.id }) }
  end

  test "Verify all queues each added login and token and returns their request ids without writing events" do
    login = @scenario.credential(state: "signed_out")
    token = @scenario.token_credential
    @scenario.credential(added: false)
    @scenario.token_credential(added: false)
    Scenario.new.credential

    written = events_written { @outcome = verify_all }

    assert_empty written
    requests = HelperRequest.where(workspace_id: @scenario.workspace_id).index_by(&:credential_id)
    assert_equal 2, HelperRequest.where(workspace_id: @scenario.workspace_id).count
    assert_equal [ login.id, token.id ].sort, requests.keys.sort
    assert_equal [ "helper_request_ids" ], @outcome.result.keys
    assert_equal requests.values.map(&:id).sort, @outcome.result.fetch("helper_request_ids").sort
    [ login, token ].each do |credential|
      request = requests.fetch(credential.id)
      assert_equal [ "verify", "queued", nil ], [ request.kind, request.state, request.seat_id ]
      assert_equal({ "provider" => credential.provider, "credential_kind" => credential.kind }, request.params)
    end
  end

  test "Verify all keeps queued and picked-up verifies and queues a fresh verify after a finished one" do
    login = @scenario.credential
    token = @scenario.token_credential
    verified = @scenario.credential(provider: "codex")
    queued = queue_request("verify", credential: login)
    picked_up = queue_request("verify", credential: token, state: "picked_up")
    finished = queue_request("verify", credential: verified, state: "finished")

    outcome = verify_all

    requests = HelperRequest.where(workspace_id: @scenario.workspace_id, kind: "verify")
    assert_equal 4, requests.count
    fresh = requests.where(credential_id: verified.id).where.not(id: finished.id).sole
    assert_equal "queued", fresh.state
    assert_equal [ queued.id, picked_up.id, fresh.id ].sort, outcome.result.fetch("helper_request_ids").sort
    assert_equal [ "queued", "picked_up", "finished" ], [ queued.reload.state, picked_up.reload.state, finished.reload.state ]
  end

  test "a repeat of a Verify all key answers the original ids without another request or event" do
    @scenario.credential
    key = new_key
    first = verify_all(key: key)
    @scenario.token_credential

    written = events_written do
      repeat = assert_completed(owner_command("verify_credential", key: key))
      assert_equal first.result, repeat.result
    end

    assert_empty written
    assert_equal 1, HelperRequest.where(workspace_id: @scenario.workspace_id).count
  end

  test "a single Verify still queues a fresh request even when a verify is unfinished" do
    token = @scenario.token_credential
    existing = queue_request("verify", credential: token)
    key = new_key
    params = { "id" => token.id }
    first = assert_completed(owner_command("verify_credential", params, key: key))
    fresh = HelperRequest.find(first.result.fetch("helper_request_id"))

    assert_not_equal existing.id, fresh.id
    assert_equal [ token.id, "verify", "queued" ], [ fresh.credential_id, fresh.kind, fresh.state ]
    repeat = assert_completed(owner_command("verify_credential", params, key: key))
    assert_equal first.result, repeat.result
    assert_equal 2, HelperRequest.where(workspace_id: @scenario.workspace_id, credential_id: token.id).count
  end

  private

  def verify_all(**options)
    assert_completed(owner_command("verify_credential", {}, **options))
  rescue T::NotFound
    flunk "Verify all should not require one credential id"
  end
end
