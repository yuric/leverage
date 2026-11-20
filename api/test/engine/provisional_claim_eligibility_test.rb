require "test_helper"
require_relative "entries/gated_flow_support"

# A provisional claim completes only for a seat that may still claim when
# its check passes (PRD L545, L392; milestone 3 plan HD-4): enabled, not
# paused, not removed, and its run on its first available candidate. A seat
# whose only login is limited or signed out while the claim waits gets the
# claim refused invalid_state, and the task is back in Ready with no holder
# (milestone 4 review, finding 7).
class ProvisionalClaimEligibilityTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup do
    use_scenario
    @orchestrator = online_orchestrator
    @rule = model_rule(hook: "task.before_claim")
    @task = scenario.task(state: "ready")
    @login = scenario.credential(provider: "claude")
    @builder = scenario.seat(role: "builder", credential: @login)
    @key = new_key
    assert_equal :pending, seat_command(@builder, "claim", {}, key: @key).outcome
    assert_equal @builder.id, @task.reload.holder_seat_id
  end

  def assert_lapsed
    answer_next(@orchestrator, PASSED)

    row = command_row(@builder, @key)
    assert_equal [ "refused", "invalid_state" ], [ row.outcome, row.refusal&.fetch("code") ]
    @task.reload
    assert_equal [ "ready", nil, nil ], [ @task.state, @task.holder_seat_id, @task.builder_seat_id ]
    assert_empty Event.where(workspace_id: scenario.workspace_id, task_id: @task.id, type: "task.claimed")
  end

  test "the claim completes when the seat may still claim" do
    answer_next(@orchestrator, PASSED)

    assert_equal "completed", command_row(@builder, @key).outcome
    assert_equal [ "working", @builder.id, @login.id ], @task.reload.attributes.values_at("state", "holder_seat_id",
      "credential_id")
  end

  test "the seat's only login limited while the claim waits refuses it invalid_state" do
    scenario.limit_credential(@login, reset_at: scenario.database_now + 3600)

    assert_lapsed
  end

  test "every login of the seat signed out while the claim waits refuses it invalid_state" do
    scenario.sign_out_credential(@login)

    assert_lapsed
  end

  test "the seat paused while the claim waits refuses it" do
    @builder.update_columns(paused: true)

    assert_lapsed
  end
end
