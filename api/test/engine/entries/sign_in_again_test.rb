require "test_helper"
require_relative "accounts_support"

# sign_in_again (PRD L198, L611, L697; milestone 3 plan HE-36): for an added
# login the owner asks the helper to open the provider's own sign-in. It
# queues one open_sign_in request, with the provider and kind as params and
# never the name, or answers the unfinished one for that account, and
# writes no event. Anything but an added login is 422 invalid; an id that
# is not a credential of the workspace is 404. What the helper then reports
# is report_request_result's (its test).
class SignInAgainTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  def sign_in(credential_id, **options) = owner_command("sign_in_again", { "id" => credential_id }, **options)

  def requests(credential) = HelperRequest.where(credential_id: credential.id, kind: "open_sign_in").order(:requested_at, :id).to_a

  test "it queues one open_sign_in for a signed-out login, with no event, and answers its id" do
    credential = @scenario.credential(provider: "claude", state: "signed_out")
    key = new_key
    written = events_written { @outcome = assert_completed(sign_in(credential.id, key: key)) }

    assert_empty written
    request = HelperRequest.find(@outcome.result.fetch("helper_request_id"))
    assert_equal({ "helper_request_id" => request.id }, @outcome.result)
    assert_equal [ "open_sign_in", "queued", nil, credential.id ],
      [ request.kind, request.state, request.seat_id, request.credential_id ]
    assert_equal({ "provider" => "claude", "credential_kind" => "login" }, request.params)
    refute_includes request.attributes.to_json, credential.name
    assert_equal @outcome.result, Command.find_by!(key: key).result
    assert_equal "signed_out", credential.reload.state, "nothing changes until the helper reports"
  end

  test "an active login may be signed in again too" do
    credential = @scenario.credential(provider: "codex")

    assert_completed(sign_in(credential.id))

    assert_equal 1, requests(credential).size
  end

  test "while one is unfinished, a second answers it and queues none" do
    credential = @scenario.credential(provider: "claude", state: "signed_out")
    first = assert_completed(sign_in(credential.id))
    assert_equal first.result, assert_completed(sign_in(credential.id)).result

    requests(credential).first.update!(state: "picked_up", picked_up_at: @scenario.database_now)
    assert_equal first.result, assert_completed(sign_in(credential.id)).result
    assert_equal 1, requests(credential).size
  end

  test "once the earlier one has finished, a new one is queued" do
    credential = @scenario.credential(provider: "claude", state: "signed_out")
    first = assert_completed(sign_in(credential.id))
    requests(credential).first.update!(state: "failed", finished_at: @scenario.database_now)

    second = assert_completed(sign_in(credential.id))

    refute_equal first.result, second.result
    assert_equal %w[failed queued], requests(credential).map(&:state)
  end

  test "another account's unfinished sign-in is not this one's" do
    one = @scenario.credential(provider: "claude", state: "signed_out")
    two = @scenario.credential(provider: "codex", state: "signed_out")
    first = assert_completed(sign_in(one.id))

    refute_equal first.result, assert_completed(sign_in(two.id)).result
  end

  test "a login whose add is still running is not an added login: invalid" do
    credential = @scenario.credential(provider: "claude", added: false)

    assert_raises(T::Invalid) { sign_in(credential.id) }
    assert_empty requests(credential)
  end

  test "an API token is not a login: invalid" do
    credential = @scenario.credential(provider: "openai_api", kind: "api_token")

    assert_raises(T::Invalid) { sign_in(credential.id) }
    assert_empty requests(credential)
  end

  test "a credential of another workspace, or none, is not found" do
    other = Scenario.new
    elsewhere = other.credential(provider: "claude")

    assert_raises(T::NotFound) { sign_in(elsewhere.id) }
    assert_raises(T::NotFound) { sign_in(SecureRandom.uuid) }
    assert_equal 0, HelperRequest.where(kind: "open_sign_in", workspace_id: @scenario.workspace_id).count
  end
end
