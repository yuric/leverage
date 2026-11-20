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
end
