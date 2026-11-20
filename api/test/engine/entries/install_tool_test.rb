require "test_helper"
require_relative "accounts_support"

# install_tool (PRD L605; milestone 2 plan IN-23, PV-5): after the owner
# confirmed what will be installed and from where, queues an install_tool
# request for a login provider's tool and writes no event.
class InstallToolTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "it queues install_tool with the provider and writes no event" do
    written = events_written do
      @outcome = assert_completed(owner_command("install_tool", { "provider" => "codex", "confirmed" => true }))
    end

    assert_empty written
    request = HelperRequest.find(@outcome.result.fetch("helper_request_id"))
    assert_equal [ "install_tool", "queued", nil, nil ], [ request.kind, request.state, request.seat_id, request.credential_id ]
    assert_equal({ "provider" => "codex" }, request.params)
  end

  test "an API provider has no tool to install" do
    assert_raises(T::Invalid) { owner_command("install_tool", { "provider" => "openai_api", "confirmed" => true }) }
  end

  test "an install the owner did not confirm is invalid" do
    assert_raises(T::Invalid) { owner_command("install_tool", { "provider" => "codex", "confirmed" => false }) }
  end
end
