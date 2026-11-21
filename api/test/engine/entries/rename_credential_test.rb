require "test_helper"
require_relative "accounts_support"

class RenameCredentialTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "renames an added token without putting its name in the event or receipt" do
    credential = scenario.token_credential
    name = "Made-up new account name"
    request = owner_request("rename_credential", { "id" => credential.id, "name" => name })

    outcome = nil
    written = events_written { outcome = T.apply(request) }

    assert_completed outcome
    assert_equal [ "credential.renamed" ], written.map(&:type)
    event = written.first
    assert_equal credential.id, event.subject_id
    assert_equal "credential", event.subject_kind
    assert_equal request.key, event.command_id
    assert_equal({}, event.payload)
    assert_nil Command.find_by!(key: request.key).result
    assert_equal name, credential.reload.name

    assert_empty events_written { assert_nil T.apply(request).result }
  end

  test "refuses a name used by another credential of the same provider and kind" do
    credential = scenario.credential
    pending = scenario.credential(added: false)
    original_name = credential.name

    assert_empty events_written {
      assert_refused "duplicate_name", rename(credential, pending.name)
    }
    assert_equal original_name, credential.reload.name
  end

  test "the same name is allowed for another provider or workspace" do
    credential = scenario.credential
    name = "Made-up shared name"
    scenario.token_credential(provider: "claude_api", name: name)
    scenario.credential(provider: "codex", name: name)
    Scenario.new.credential(name: name)

    assert_completed rename(credential, name)
    assert_equal name, credential.reload.name
  end

  test "accepts the credential's own name without a duplicate name refusal" do
    credential = scenario.credential

    written = events_written { assert_completed rename(credential, credential.name) }

    assert_empty written
  end

  test "Rename trims names before saving and checking other names" do
    credential = scenario.credential
    scenario.credential(name: " Made-up taken ", added: false)
    assert_refused "duplicate_name", rename(credential, "Made-up taken\t")
    assert_completed rename(credential, "  Made-up new  ")
    assert_equal "Made-up new", credential.reload.name
    assert_empty events_written { assert_completed rename(credential, " Made-up new ") }
  end

  test "rejects an empty name without changing the credential" do
    credential = scenario.credential
    original_name = credential.name

    assert_empty events_written { assert_raises(T::Invalid) { rename(credential, " \t ") } }
    assert_equal original_name, credential.reload.name
  end

  test "does not find unknown credentials, unfinished adds or credentials of another workspace" do
    unknown = Credential.new(id: SecureRandom.uuid)
    pending = scenario.credential(added: false)
    elsewhere = Scenario.new.credential

    [ unknown, pending, elsewhere ].each do |credential|
      assert_raises(T::NotFound) { rename(credential, "Made-up name") }
    end
  end

  private

  def rename(credential, name)
    owner_command("rename_credential", { "id" => credential.id, "name" => name })
  end
end
