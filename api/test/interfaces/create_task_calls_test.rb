require "test_helper"
require_relative "../engine/entries/gated_flow_support"

class CreateTaskCallsTest < ActionDispatch::IntegrationTest
  include GatedFlowSupport

  setup do
    use_scenario
    @creator = scenario.seat(role: "planner")
    @headers = { "Authorization" => "Bearer #{scenario.token_for(@creator)}", "Idempotency-Key" => new_key }
    @body = contract_body.slice("title", "details", "criteria")
  end

  test "the agent endpoint rejects owner-only fields before creating anything" do
    %w[actions state minimum_strength_rank budget_cap].each do |field|
      assert_no_difference("Task.count") do
        post "/v1/tasks", params: @body.merge(field => []), headers: @headers, as: :json
        assert_response :bad_request
      end
    end
  end

  { "ready" => GatedFlowSupport::PASSED, "backlog" => GatedFlowSupport::FAILED, "cancelled" => nil }.each do |state, verdict|
    test "get_command reports the created task after its pending check ends in #{state}" do
      orchestrator = online_orchestrator
      model_rule
      post "/v1/tasks", params: @body, headers: @headers, as: :json
      assert_response :accepted
      assert_equal "pending", response.parsed_body["outcome"]
      task = Task.find_by!(workspace_id: scenario.workspace_id, title: @body["title"])
      if verdict
        answer_next(orchestrator, verdict)
      else
        assert_completed(owner_command("cancel", { "id" => task.id }))
      end
      get "/v1/commands/#{@headers.fetch("Idempotency-Key")}", headers: @headers
      assert_response :ok
      if verdict
        assert_equal [ "completed", { "task_id" => task.id, "state" => state } ], response.parsed_body.values_at("outcome", "result")
      else
        assert_equal [ "refused", "task_cancelled" ], [ response.parsed_body["outcome"], response.parsed_body.dig("refusal", "code") ]
      end
      assert_equal state, task.reload.state
    end
  end
end
