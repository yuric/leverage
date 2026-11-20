require "test_helper"

# Routes come from the registry (milestone 2 plan IN-1, §2.1): routes.rb
# draws one route per Leverage::Http::RouteTable entry, with the registry's
# method and path, and types no path of its own.
class RoutesTest < ActiveSupport::TestCase
  RouteTable = Leverage::Http::RouteTable

  # The operations milestone 2 serves (plan §2.3): 16 agent calls, the
  # health check, 20 owner calls, 5 helper calls, then the six additions.
  SERVED = %w[
    get_next get_command claim_next_task get_task_briefing acknowledge_task_briefing heartbeat_task start_criterion
    pass_criterion submit_task release_task claim_next_review heartbeat_review release_review get_review_briefing
    acknowledge_review_briefing give_verdict
    get_health
    sign_in_owner get_owner_command list_events get_board get_task list_seats list_credentials get_system_health add_task
    complete_contract cancel_task allow_another_round connect_seat start_seat stop_seat remove_seat issue_helper_token
    add_credential verify_credential install_tool
    get_helper_next report_request_result issue_seat_token report_run_started report_run_stopped
    get_setup_state create_owner sign_out_owner get_helper_request report_request_progress get_landing_prompt
  ].freeze

  def operations = Leverage::Contract.registry.fetch("operations").index_by { |operation| operation.fetch("operation_id") }

  def drawn
    Rails.application.routes.routes.select(&:name).index_by(&:name)
  end

  test "the route table serves exactly milestone 2's operations, each a registry operation" do
    assert_equal SERVED.sort, RouteTable::ROUTES.keys.sort
    RouteTable::ROUTES.each_key { |operation_id| assert operations.key?(operation_id), operation_id }
  end

  test "each served operation is drawn with the registry's method and path, to its controller and action" do
    routes = drawn
    RouteTable::ROUTES.each do |operation_id, target|
      route = routes.fetch(operation_id) { flunk "no route named #{operation_id}" }
      operation = operations.fetch(operation_id)
      controller, action = target.split("#")

      assert_equal operation.fetch("method"), route.verb, operation_id
      assert_equal operation.fetch("path").gsub(/\{([a-z]+)\}/, ':\1'), route.path.spec.to_s, operation_id
      assert_equal [ controller, action ], route.defaults.values_at(:controller, :action), operation_id
    end
  end

  test "each controller is one of the plan's, under v1/agent, v1/owner, v1/helper or the health check" do
    allowed = %r{\Av1/(agent/(next|commands|tasks|criteria|reviews)|owner/(setup|sessions|commands|events|board|tasks|seats|credentials|tools|helpers|helper_requests|health)|helper/(next|requests|seats)|health)\z}
    RouteTable::ROUTES.each_value { |target| assert_match allowed, target.split("#").first }
  end

  test "routes.rb types no path of the interface" do
    source = Rails.root.join("config/routes.rb").read
    assert_no_match(%r{["']/?v1}, source)
  end

  test "the route table's rails paths and verbs are read from the registry" do
    route = RouteTable.routes.find { |candidate| candidate.operation_id == "start_criterion" }
    assert_equal [ "post", "/v1/tasks/:id/criteria/:cid/start", "v1/agent/criteria#start" ],
      [ route.verb, route.path, route.to ]
  end
end
