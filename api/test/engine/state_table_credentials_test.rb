require "test_helper"
require_relative "entries/accounts_support"

# The owner credential rows of the state table (test 3).
class StateTableCredentialsTest < ActiveSupport::TestCase
  include AccountsSupport

  COMMANDS = %w[add_credential verify_credential].freeze
  NEW_COMMANDS = %w[rename_credential remove_credential reorder_credentials refresh_usage].freeze

  setup { use_scenario }

  def caller_of(command) = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
    .find { |row| row.fetch("command") == command }.fetch("who").first

  def request_for(command)
    case command
    when "add_credential"
      owner_request(command, { "credential_id" => SecureRandom.uuid, "kind" => "login", "provider" => "codex",
                               "name" => "Made-up table account", "masked_label" => nil, "model" => nil, "effort" => nil,
                               "strength_rank" => nil })
    when "verify_credential" then owner_request(command, { "id" => scenario.credential.id })
    when "rename_credential"
      owner_request(command, { "id" => scenario.credential.id, "name" => "Made-up renamed account" })
    when "remove_credential" then owner_request(command, { "id" => scenario.credential.id })
    when "reorder_credentials"
      first = scenario.credential
      last = scenario.token_credential
      owner_request(command, { "order" => [ last.id, first.id ] })
    when "refresh_usage"
      scenario.credential
      owner_request(command)
    else
      flunk "no request for #{command}"
    end
  end

  StateTableCases.define(self, COMMANDS + NEW_COMMANDS) do |kase|
    assert_nil kase.from, "the credential rows read no task state"
    assert_nil kase.to, "the credential rows change no task state"
    assert_nil kase.refusal
    assert_nil kase.hook, "no credential row has a hook"

    request = request_for(kase.command)
    assert_equal caller_of(kase.command), request.caller_kind
    written = events_written { @outcome = T.apply(request) }

    assert_completed(@outcome)
    expected = kase.command == "reorder_credentials" ? kase.events * 2 : kase.events
    assert_equal expected, written.map(&:type), "#{kase.command} writes exactly the row's events"
    assert Command.exists?(key: request.key, command: kase.command), "#{kase.command} stores its commands row"
  end
end
