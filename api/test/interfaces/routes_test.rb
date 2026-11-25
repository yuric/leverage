require "test_helper"

# Routes come from the registry (milestone 2 plan IN-1, §2.1): routes.rb
# draws one route per Leverage::Http::RouteTable entry, with the registry's
# method and path, and types no path of its own.
class RoutesTest < ActiveSupport::TestCase
  RouteTable = Leverage::Http::RouteTable

  # The operations milestone 2 serves (plan §2.3): 16 agent calls, the
  # health check, 20 owner calls, 5 helper calls, then the six additions.
  MILESTONE_2 = %w[
    get_next get_command claim_next_task get_task_briefing acknowledge_task_briefing heartbeat_task start_criterion
    pass_criterion submit_task release_task claim_next_review heartbeat_review release_review get_review_briefing
    acknowledge_review_briefing give_verdict
    get_health
    sign_in_owner get_owner_command list_events get_board get_task list_seats list_credentials get_system_health add_task
    complete_contract cancel_task allow_another_round connect_seat start_seat stop_seat remove_seat issue_helper_token
    add_credential verify_credential install_tool
    get_helper_next report_request_result issue_seat_token report_run_started report_run_stopped
    get_setup_state create_owner sign_out_owner get_helper_request report_request_progress
  ].freeze

  # The eleven operations milestone 3 serves (milestone 3 plan §2.3).
  MILESTONE_3 = %w[
    report_limit report_signed_out sign_in_again list_inbox promote_task edit_contract hold_task resume_task pause_seat
    resume_seat change_seat
  ].freeze

  # The twelve operations milestone 4 serves (milestone 4 plan §2.3).
  MILESTONE_4 = %w[
    claim_next_job submit_job_result list_rules add_rule save_rule enable_rule disable_rule revert_rule remove_rule
    rerun_check override_check draft_contract
  ].freeze

  # The thirty operations milestone 5 serves (AT-6).
  MILESTONE_5 = %w[
    ask_question get_question request_access report_cost start_action report_action_done list_decisions
    list_projects create_project edit_brief pause_project resume_project change_budget delete_project_content
    change_task_priority change_task_project change_task_cap return_for_rework offer_task_again grant_access
    delete_task_content answer_question overturn_answer approve_action stop_action waive_action mark_action_done
    overturn_approval get_workspace_settings change_workspace_settings
  ].freeze

  MILESTONE_6 = %w[
    rename_credential remove_credential reorder_credentials refresh_usage verify_all_credentials report_reading
  ].freeze

  JOIN_OPERATIONS = {
    "get_join" => [ "GET", "/v1/join", "v1/agent/join#show" ],
    "issue_landing_prompt" => [ "POST", "/v1/owner/seats/:id/landing-prompt", "v1/owner/seats#issue_landing_prompt" ]
  }.freeze

  ROUND_2_OPERATIONS = {
    "report_model" => [ "POST", "/v1/seat/model", "v1/agent/seats#report_model" ],
    "create_task" => [ "POST", "/v1/tasks", "v1/agent/tasks#create" ]
  }.freeze

  def operations = Leverage::Contract.registry.fetch("operations").index_by { |operation| operation.fetch("operation_id") }

  def drawn
    Rails.application.routes.routes.select(&:name).index_by(&:name)
  end

  test "the served operations match their milestones, each a registry operation" do
    refute RouteTable.const_defined?(:PENDING, false)
    assert_equal operations.keys.sort, RouteTable::ROUTES.keys.sort
    expected = MILESTONE_2 + MILESTONE_3 + MILESTONE_4 + MILESTONE_5 + MILESTONE_6 + JOIN_OPERATIONS.keys + ROUND_2_OPERATIONS.keys
    assert_equal (expected + %w[get_owner_identity]).sort, RouteTable::ROUTES.keys.sort
    RouteTable::ROUTES.each_key { |operation_id| assert operations.key?(operation_id), operation_id }
    RouteTable.routes.each do |route|
      operation = operations.fetch(route.operation_id)
      assert_equal [ operation.fetch("method").downcase, operation.fetch("path").gsub(/\{([a-z]+)\}/, ':\1') ],
        [ route.verb, route.path ], route.operation_id
    end
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

  test "each controller is one of the plans', under v1/agent, v1/owner, v1/helper or the health check" do
    allowed = %r{\Av1/(agent/(actions|questions|join|next|commands|tasks|criteria|reviews|jobs|seats)|owner/(actions|questions|projects|decisions|settings|setup|sessions|commands|events|board|tasks|seats|credentials|tools|helpers|helper_requests|health|inbox|rules|rule_checks)|helper/(next|requests|seats|credentials)|health)\z}
    RouteTable::ROUTES.each_value { |target| assert_match allowed, target.split("#").first }
  end

  test "routes.rb types no path of the interface" do
    source = Rails.root.join("config/routes.rb").read
    assert_no_match(%r{["']/?v1}, source)
  end

  test "join and prompt issuance replace the old landing prompt read" do
    JOIN_OPERATIONS.each do |operation_id, (verb, path, target)|
      assert_equal target, RouteTable::ROUTES[operation_id]
      assert_equal [ verb, path ], [ drawn.fetch(operation_id).verb, drawn.fetch(operation_id).path.spec.to_s ]
    end
    refute RouteTable.serves?("get_landing_prompt")
    refute drawn.key?("get_landing_prompt")
  end

  test "the Round 2 operations use their registered routes and actions" do
    ROUND_2_OPERATIONS.each do |operation_id, (verb, path, target)|
      assert_equal target, RouteTable::ROUTES[operation_id]
      route = drawn.fetch(operation_id)
      assert_equal [ verb, path ], [ route.verb, route.path.spec.to_s ]
    end
  end

  test "the route table's rails paths and verbs are read from the registry" do
    route = RouteTable.routes.find { |candidate| candidate.operation_id == "start_criterion" }
    assert_equal [ "post", "/v1/tasks/:id/criteria/:cid/start", "v1/agent/criteria#start" ],
      [ route.verb, route.path, route.to ]
  end
end
