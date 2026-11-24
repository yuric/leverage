module Leverage
  module Http
    # The operations served, each to its controller and action (milestone 2
    # plan §2.1, §2.3, IN-1; the later milestones are grouped below).
    # config/routes.rb draws one route per entry with the registry's method
    # and path, so no path is typed anywhere else; every other registry
    # operation has no route and answers 404 (test/interfaces/seams_test.rb).
    module RouteTable
      ROUTES = {
        # Agent: the sixteen calls of plan §2.3.
        "get_next" => "v1/agent/next#show",
        "get_command" => "v1/agent/commands#show",
        "claim_next_task" => "v1/agent/tasks#claim_next",
        "get_task_briefing" => "v1/agent/tasks#briefing",
        "acknowledge_task_briefing" => "v1/agent/tasks#acknowledge_briefing",
        "heartbeat_task" => "v1/agent/tasks#heartbeat",
        "start_criterion" => "v1/agent/criteria#start",
        "pass_criterion" => "v1/agent/criteria#pass",
        "submit_task" => "v1/agent/tasks#submit",
        "release_task" => "v1/agent/tasks#release",
        "claim_next_review" => "v1/agent/reviews#claim_next",
        "heartbeat_review" => "v1/agent/reviews#heartbeat",
        "release_review" => "v1/agent/reviews#release",
        "get_review_briefing" => "v1/agent/reviews#briefing",
        "acknowledge_review_briefing" => "v1/agent/reviews#acknowledge_briefing",
        "give_verdict" => "v1/agent/reviews#verdict",
        # Infrastructure.
        "get_health" => "v1/health#show",
        # Owner.
        "get_setup_state" => "v1/owner/setup#show",
        "create_owner" => "v1/owner/setup#create",
        "sign_in_owner" => "v1/owner/sessions#create",
        "sign_out_owner" => "v1/owner/sessions#sign_out",
        "get_owner_command" => "v1/owner/commands#show",
        "list_events" => "v1/owner/events#index",
        "get_board" => "v1/owner/board#show",
        "get_task" => "v1/owner/tasks#show",
        "list_seats" => "v1/owner/seats#index",
        "list_credentials" => "v1/owner/credentials#index",
        "get_system_health" => "v1/owner/health#show",
        "get_helper_request" => "v1/owner/helper_requests#show",
        "add_task" => "v1/owner/tasks#create",
        "complete_contract" => "v1/owner/tasks#complete_contract",
        "cancel_task" => "v1/owner/tasks#cancel",
        "allow_another_round" => "v1/owner/tasks#allow_another_round",
        "connect_seat" => "v1/owner/seats#create",
        "start_seat" => "v1/owner/seats#start",
        "stop_seat" => "v1/owner/seats#stop",
        "remove_seat" => "v1/owner/seats#remove",
        "get_landing_prompt" => "v1/owner/seats#landing_prompt",
        "issue_helper_token" => "v1/owner/helpers#create",
        "add_credential" => "v1/owner/credentials#create",
        "verify_credential" => "v1/owner/credentials#verify",
        "install_tool" => "v1/owner/tools#install",
        # Helper.
        "get_helper_next" => "v1/helper/next#show",
        "report_request_progress" => "v1/helper/requests#progress",
        "report_request_result" => "v1/helper/requests#result",
        "issue_seat_token" => "v1/helper/seats#seat_token",
        "report_run_started" => "v1/helper/seats#run_started",
        "report_run_stopped" => "v1/helper/seats#run_stopped",
        # Milestone 3's eleven (its plan §2.3, HT-6).
        "report_limit" => "v1/helper/credentials#limit_reached",
        "report_signed_out" => "v1/helper/credentials#signed_out",
        "sign_in_again" => "v1/owner/credentials#sign_in",
        "list_inbox" => "v1/owner/inbox#index",
        "promote_task" => "v1/owner/tasks#promote",
        "edit_contract" => "v1/owner/tasks#contract",
        "hold_task" => "v1/owner/tasks#hold",
        "resume_task" => "v1/owner/tasks#resume",
        "pause_seat" => "v1/owner/seats#pause",
        "resume_seat" => "v1/owner/seats#resume",
        "change_seat" => "v1/owner/seats#change",
        # Milestone 4's twelve (its plan §2.3, RT-6).
        "claim_next_job" => "v1/agent/jobs#claim_next",
        "submit_job_result" => "v1/agent/jobs#result",
        "list_rules" => "v1/owner/rules#index",
        "add_rule" => "v1/owner/rules#create",
        "save_rule" => "v1/owner/rules#versions",
        "enable_rule" => "v1/owner/rules#enable",
        "disable_rule" => "v1/owner/rules#disable",
        "revert_rule" => "v1/owner/rules#revert",
        "remove_rule" => "v1/owner/rules#remove",
        "rerun_check" => "v1/owner/rule_checks#rerun",
        "override_check" => "v1/owner/rule_checks#override",
        "draft_contract" => "v1/owner/tasks#draft_contract",
        # Milestone 5's thirty (its plan §2.3, AT-6).
        "ask_question" => "v1/agent/questions#create",
        "get_question" => "v1/agent/questions#show",
        "request_access" => "v1/agent/tasks#access",
        "report_cost" => "v1/agent/tasks#cost",
        "start_action" => "v1/agent/actions#start",
        "report_action_done" => "v1/agent/actions#done",
        "list_decisions" => "v1/owner/decisions#index",
        "list_projects" => "v1/owner/projects#index",
        "create_project" => "v1/owner/projects#create",
        "edit_brief" => "v1/owner/projects#brief",
        "pause_project" => "v1/owner/projects#pause",
        "resume_project" => "v1/owner/projects#resume",
        "change_budget" => "v1/owner/projects#budget",
        "delete_project_content" => "v1/owner/projects#delete_content",
        "change_task_priority" => "v1/owner/tasks#priority",
        "change_task_project" => "v1/owner/tasks#project",
        "change_task_cap" => "v1/owner/tasks#cap",
        "return_for_rework" => "v1/owner/tasks#rework",
        "offer_task_again" => "v1/owner/tasks#offer_again",
        "grant_access" => "v1/owner/tasks#grant_access",
        "delete_task_content" => "v1/owner/tasks#delete_content",
        "answer_question" => "v1/owner/questions#answer",
        "overturn_answer" => "v1/owner/questions#overturn",
        "approve_action" => "v1/owner/actions#approve",
        "stop_action" => "v1/owner/actions#stop",
        "waive_action" => "v1/owner/actions#waive",
        "mark_action_done" => "v1/owner/actions#mark_done",
        "overturn_approval" => "v1/owner/actions#overturn",
        "get_workspace_settings" => "v1/owner/settings#show",
        "change_workspace_settings" => "v1/owner/settings#update",
        # Milestone 6's six (its plan §2.3, CT-1).
        "rename_credential" => "v1/owner/credentials#rename",
        "remove_credential" => "v1/owner/credentials#remove",
        "reorder_credentials" => "v1/owner/credentials#reorder",
        "refresh_usage" => "v1/owner/credentials#refresh",
        "verify_all_credentials" => "v1/owner/credentials#verify_all",
        "report_reading" => "v1/helper/credentials#readings"
      }.freeze

      # One served operation as routes.rb draws it: verb is "get" or "post",
      # path the registry's path with {id} written :id.
      Route = Data.define(:operation_id, :verb, :path, :to)

      module_function

      def serves?(operation_id) = ROUTES.key?(operation_id)

      # The served operations, read from the registry; or those of table (a
      # test's own). Raises KeyError for a key that is not a registry
      # operation.
      def routes(table = ROUTES)
        operations = Contract.registry.fetch("operations").to_h { |operation| [ operation.fetch("operation_id"), operation ] }
        table.map do |operation_id, to|
          operation = operations.fetch(operation_id) { raise KeyError, "#{operation_id} is not a registry operation" }
          Route.new(operation_id: operation_id, verb: operation.fetch("method").downcase,
                    path: operation.fetch("path").gsub(/\{([a-z]+)\}/, ':\1'), to: to)
        end
      end
    end
  end
end
