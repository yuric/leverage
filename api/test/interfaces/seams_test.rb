require "test_helper"

# The seam to later milestones, from data (milestone 2 plan §1.2): every
# registry operation that Leverage::Http::RouteTable does not serve answers
# 404 not_found to a caller with valid sign-in, and writes no commands row
# and no event; every RouteTable key is a registry operation.
class SeamsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  setup do
    @scenario = Scenario.new
    @tokens = { seat: @scenario.token_for(@scenario.seat), owner: @scenario.owner_token, helper: @scenario.helper_token }
  end

  def operations = Leverage::Contract.registry.fetch("operations")

  def unserved = operations.reject { |operation| Leverage::Http::RouteTable.serves?(operation.fetch("operation_id")) }

  def token_for(caller)
    case caller
    when "owner" then @tokens[:owner]
    when "helper" then @tokens[:helper]
    when "public" then nil
    else @tokens[:seat]
    end
  end

  def concrete(path)
    path.gsub(/\{([a-z]+)\}/) { Regexp.last_match(1) == "provider" ? "claude" : SecureRandom.uuid }
  end

  test "every RouteTable key is a registry operation" do
    ids = operations.map { |operation| operation.fetch("operation_id") }
    Leverage::Http::RouteTable::ROUTES.each_key { |operation_id| assert_includes ids, operation_id }
  end

  test "the unserved operations are the Credentials milestone's seam" do
    ids = unserved.map { |operation| operation.fetch("operation_id") }
    assert_equal %w[refresh_usage remove_credential rename_credential reorder_credentials report_reading
                    verify_all_credentials], ids.sort
    %w[claim_next_job submit_job_result list_rules add_rule save_rule enable_rule disable_rule revert_rule remove_rule
       rerun_check override_check draft_contract].each { |operation_id| refute_includes ids, operation_id }
  end

  test "every unserved operation answers 404 with valid sign-in and writes nothing" do
    before = [ Command.count, Event.count ]
    unserved.each do |operation|
      headers = { "Idempotency-Key" => "seam-#{SecureRandom.hex(4)}", "Content-Type" => "application/json" }
      token = token_for(operation.fetch("caller"))
      headers["Authorization"] = "Bearer #{token}" if token
      path = concrete(operation.fetch("path"))
      process operation.fetch("method").downcase.to_sym, path, params: (operation.fetch("method") == "POST" ? "{}" : nil),
        headers: headers

      assert_response :not_found, "#{operation.fetch("operation_id")} #{operation.fetch("method")} #{path}"
      assert_equal "not_found", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
    assert_equal before, [ Command.count, Event.count ]
  end
end
