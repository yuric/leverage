require "test_helper"
require_relative "entries/accounts_support"

class StateTableWorkspaceTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  StateTableCases.define(self, %w[delete_content change_workspace_settings]) do |kase|
    assert_includes kase.who, "owner"
    assert_nil kase.from
    assert_nil kase.to
    assert_nil kase.hook

    params = if kase.command == "delete_content"
      state = kase.guard.include?("content_deletable") ? "done" : "backlog"
      { task_id: scenario.task(state: state).id }
    else
      { "maximum_rounds" => 5 }
    end
    written = events_written do
      outcome = owner_command(kase.command, params)
      if kase.refusal
        assert_refused kase.refusal, outcome
      else
        assert_completed outcome
      end
    end
    assert_equal kase.events, written.map(&:type)
  end
end
