require "test_helper"
require_relative "entries/accounts_support"

# The existing Add and Verify rows of the state table (test 3, PRD L836).
class StateTableCredentialsTest < ActiveSupport::TestCase
  include AccountsSupport

  COMMANDS = %w[add_credential verify_credential].freeze

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
    else
      flunk "no request for #{command}"
    end
  end

  StateTableCases.define(self, COMMANDS) do |kase|
    assert_nil kase.from, "the accounts rows read no task state"
    assert_nil kase.to, "the accounts rows change no task state"
    assert_nil kase.refusal
    assert_nil kase.hook, "no accounts row has a hook in milestone 2"

    request = request_for(kase.command)
    assert_equal caller_of(kase.command), request.caller_kind
    written = events_written { @outcome = T.apply(request) }

    assert_completed(@outcome)
    assert_equal kase.events, written.map(&:type), "#{kase.command} writes exactly the row's events"
    assert Command.exists?(key: request.key, command: kase.command), "#{kase.command} stores its commands row"
  end
end
