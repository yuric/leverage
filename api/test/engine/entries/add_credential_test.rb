require "test_helper"
require_relative "accounts_support"

# add_credential (PRD L595-L609; milestone 2 plan IN-22 to IN-24, CL-20,
# milestone 6 plan CR-7): the command inserts the credentials row at once,
# signed out and not yet added, queues the helper's add checks, and writes
# no event. The name is kept in the credential's own row and nowhere else.
class AddCredentialTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  def body(id: SecureRandom.uuid, kind: "login", provider: "claude", name: "Made-up work account", **fields)
    { "credential_id" => id, "kind" => kind, "provider" => provider, "name" => name, "masked_label" => nil,
      "model" => nil, "effort" => nil, "strength_rank" => nil }.merge(fields.transform_keys(&:to_s))
  end

  test "it inserts the row signed out with the request's fields and the next position" do
    @scenario.credential(provider: "codex")
    id = SecureRandom.uuid

    outcome = assert_completed(owner_command("add_credential",
      body(id: id, model: "made-up-model", effort: "high", strength_rank: 2)))

    row = Credential.find(id)
    assert_equal [ @scenario.workspace_id, "login", "claude", "Made-up work account", nil, "made-up-model", "high", 2 ],
      [ row.workspace_id, row.kind, row.provider, row.name, row.masked_label, row.model, row.effort, row.strength_rank ]
    assert_equal [ "signed_out", nil ], [ row.state, row.last_verified_at ]
    assert_equal 2, row.position
    assert_equal id, outcome.result.fetch("credential_id")
  end

  test "it queues run_add_checks with the provider and kind, never the name, and writes no event" do
    id = SecureRandom.uuid
    written = events_written { @outcome = assert_completed(owner_command("add_credential", body(id: id))) }

    assert_empty written
    request = HelperRequest.find(@outcome.result.fetch("helper_request_id"))
    assert_equal [ "run_add_checks", "queued", id, nil ], [ request.kind, request.state, request.credential_id, request.seat_id ]
    assert_equal({ "provider" => "claude", "credential_kind" => "login" }, request.params)
    assert_not_nil request.requested_at
    assert_not_includes request.attributes.to_json, "Made-up work account", "params never holds a name"
    assert_equal [ "credential_id", "helper_request_id" ], @outcome.result.keys.sort
  end

  test "the name is in no commands row and no helper request" do
    key = new_key
    assert_completed(owner_command("add_credential", body(name: "Made-up secret-free name"), key: key))

    assert_not_includes Command.find_by!(key: key).attributes.to_json, "Made-up secret-free name"
    assert_not HelperRequest.where(workspace_id: @scenario.workspace_id).any? { |row| row.attributes.to_json.include?("Made-up secret-free name") }
  end

  test "a second add with the same name, provider and kind is duplicate_name while the first still runs" do
    assert_completed(owner_command("add_credential", body(name: "Made-up twin")))
    counts = -> { [ Credential.count, HelperRequest.count, Event.count ] }
    before = counts.call

    assert_refused("duplicate_name", owner_command("add_credential", body(name: "Made-up twin")))
    assert_equal before, counts.call
  end

  test "Add trims names and rejects a blank name" do
    id = SecureRandom.uuid
    assert_completed owner_command("add_credential", body(id: id, name: "  Made-up account\t"))
    assert_equal "Made-up account", Credential.find(id).name
    assert_raises(T::Invalid) { owner_command("add_credential", body(name: " \t ")) }
  end

  test "Add checks the trimmed name against existing and pending names" do
    scenario.credential(name: "  Made-up account ", added: false)
    assert_refused "duplicate_name", owner_command("add_credential", body(name: "\tMade-up account "))
  end

  test "the same name with another provider is a new credential" do
    assert_completed(owner_command("add_credential", body(name: "Made-up shared name")))

    assert_completed(owner_command("add_credential", body(name: "Made-up shared name", provider: "codex")))
  end

  test "an added credential's name is duplicate_name too" do
    @scenario.credential(provider: "codex", name: "Made-up taken")

    assert_refused("duplicate_name", owner_command("add_credential", body(provider: "codex", name: "Made-up taken")))
  end

  %w[claude_api openai_api gemini_api grok_api openrouter].each do |provider|
    test "adding a token for #{provider} keeps the fixed mask and queues one add check" do
      params = body(kind: "api_token", provider: provider, name: "Made-up token name", masked_label: "••••••••")
      id = params.fetch("credential_id")
      written = events_written do
        @outcome = add_token(params)
      end

      assert_empty written
      row = Credential.find(id)
      assert_equal [ "api_token", provider, "Made-up token name", "••••••••", "signed_out", nil ],
        [ row.kind, row.provider, row.name, row.masked_label, row.state, row.last_verified_at ]
      requests = HelperRequest.where(workspace_id: @scenario.workspace_id)
      assert_equal 1, requests.count
      request = requests.first
      assert_equal({ "credential_id" => id, "helper_request_id" => request.id }, @outcome.result)
      assert_equal [ "run_add_checks", "queued", id, nil ], [ request.kind, request.state, request.credential_id, request.seat_id ]
      assert_equal({ "provider" => provider, "credential_kind" => "api_token" }, request.params)
      assert_not_includes request.attributes.to_json, "Made-up token name"
    end
  end

  test "an API token requires the fixed masked label" do
    params = body(kind: "api_token", provider: "claude_api")

    [ params, params.except("masked_label"), params.merge("masked_label" => "...made") ].each do |invalid|
      assert_raises(T::Invalid) { owner_command("add_credential", invalid) }
    end
    assert_not Credential.exists?(params.fetch("credential_id"))
    assert_empty HelperRequest.where(workspace_id: @scenario.workspace_id)
  end

  test "a login cannot have a masked label" do
    params = body(masked_label: "••••••••")

    assert_raises(T::Invalid) { owner_command("add_credential", params) }
    assert_not Credential.exists?(params.fetch("credential_id"))
    assert_empty HelperRequest.where(workspace_id: @scenario.workspace_id)
  end

  test "an API token of a login provider is invalid" do
    params = body(kind: "api_token", provider: "claude", masked_label: "••••••••")

    assert_raises(T::Invalid) { owner_command("add_credential", params) }
    assert_not Credential.exists?(params.fetch("credential_id"))
    assert_empty HelperRequest.where(workspace_id: @scenario.workspace_id)
  end

  test "a second token with the same name and provider is duplicate_name while the first still runs" do
    params = body(kind: "api_token", provider: "openrouter", name: "Made-up twin", masked_label: "••••••••")
    add_token(params)
    second = params.merge("credential_id" => SecureRandom.uuid)

    assert_refused("duplicate_name", owner_command("add_credential", second))
    assert_not Credential.exists?(second.fetch("credential_id"))
    assert_equal 1, HelperRequest.where(workspace_id: @scenario.workspace_id).count
  end

  test "a repeat of a token add key answers the same ids without another request or event" do
    key = new_key
    params = body(kind: "api_token", provider: "openai_api", masked_label: "••••••••")
    first = add_token(params, key: key)

    written = events_written do
      repeat = assert_completed(owner_command("add_credential", params, key: key))
      assert_equal first.result, repeat.result
    end

    assert_empty written
    assert_equal 1, Credential.where(workspace_id: @scenario.workspace_id).count
    assert_equal 1, HelperRequest.where(workspace_id: @scenario.workspace_id).count
  end

  test "a login of an API provider is invalid" do
    assert_raises(T::Invalid) { owner_command("add_credential", body(provider: "openrouter")) }
  end

  test "a second Gemini login is invalid (CL-20), also while the first add still runs" do
    assert_completed(owner_command("add_credential", body(provider: "gemini", name: "Made-up Gemini")))

    assert_raises(T::Invalid) { owner_command("add_credential", body(provider: "gemini", name: "Made-up other Gemini")) }
  end

  test "an id that is already a credential is invalid" do
    taken = @scenario.credential(provider: "codex")

    assert_raises(T::Invalid) { owner_command("add_credential", body(id: taken.id, name: "Made-up new name")) }
    assert_equal "codex", taken.reload.provider
  end

  test "a second Grok login is invalid even while the first add still runs" do
    assert_completed(owner_command("add_credential", body(provider: "grok")))
    assert_raises(T::Invalid) { owner_command("add_credential", body(provider: "grok", name: "Made-up other Grok")) }
  end

  test "a removed credential id cannot be used for a new account" do
    removed = @scenario.credential(provider: "codex")
    assert_completed(owner_command("remove_credential", { "id" => removed.id }))

    assert_raises(T::Invalid) { owner_command("add_credential", body(id: removed.id)) }
    assert_not Credential.exists?(removed.id)
  end

  test "Retry after a failed add sends the same id again with a new key" do
    id = SecureRandom.uuid
    first = assert_completed(owner_command("add_credential", body(id: id)))
    assert_completed(helper_command("report_request_result",
      { "id" => first.result.fetch("helper_request_id"), "result" => result_body(outcome: "failed",
        checks: [ check("tool_installed", passed: false, failure: "not_installed") ]) }))
    assert_not Credential.exists?(id)

    retry_outcome = assert_completed(owner_command("add_credential", body(id: id)))

    assert_equal id, retry_outcome.result.fetch("credential_id")
    assert Credential.exists?(id)
  end

  # Milestone 3 plan HE-5: Add credential sets strength rank 1 when the
  # request names none, and keeps the model the request carries.
  test "a request with no strength rank adds the login with rank 1 and the model it names" do
    id = SecureRandom.uuid
    assert_completed(owner_command("add_credential", body(id: id, model: "tool-default-model")))

    assert_equal [ 1, "tool-default-model", nil ], Credential.find(id).attributes.values_at("strength_rank", "model", "effort")
  end

  private

  def add_token(params, **options)
    assert_completed(owner_command("add_credential", params, **options))
  rescue T::Invalid
    flunk "Add rejected a token with the fixed mask and a matching provider"
  end
end
