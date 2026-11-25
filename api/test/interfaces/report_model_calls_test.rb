require "test_helper"
require_relative "../support/http_calls"

class ReportModelCallsTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(role: "general", model: "")
    @values = { "model" => "claude-opus-5-5", "effort" => "high" }
  end

  test "a Prompt seat reports only for itself and the event records the seat as actor" do
    other = @scenario.seat(model: "")
    key = new_key
    report(key: key)

    assert_response :ok
    assert_response_matches_contract
    assert_equal [ "change_seat", "completed", @values ], response.parsed_body.values_at("command", "outcome", "result")
    event = Event.find_by!(workspace_id: @scenario.workspace_id, command_id: key)
    assert_equal [ "seat.changed", "seat", @seat.id, "seat", @seat.id, {} ],
      [ event.type, event.actor_kind, event.actor_id, event.subject_kind, event.subject_id, event.payload ]
    assert_equal @values, @seat.reload.attributes.slice("model", "effort")
    assert_equal "", other.reload.model
    assert_nil @seat.last_polled_at
    assert_no_difference -> { Event.where(type: "seat.changed").count } do
      report
      assert_response :ok
    end
  end

  test "a Prompt seat can report while its own task submit waits on a check" do
    task = @scenario.task(state: "working", builder: @seat)
    pending = @scenario.pending_transition(task, command: "submit", requester: @seat)

    report

    assert_response :ok
    assert_response_matches_contract
    assert_equal @values, @seat.reload.attributes.slice("model", "effort")
    assert_equal "pending", pending.reload.state
    assert_equal @seat.id, task.reload.holder_seat_id
  end

  test "null clears a previous report and requires null effort" do
    @seat.update!(model: @values.fetch("model"), effort: @values.fetch("effort"))
    report(body: @values.merge("model" => nil))
    assert_response :unprocessable_entity
    assert_response_matches_contract
    assert_equal @values, @seat.reload.attributes.slice("model", "effort")

    report(body: { "model" => nil, "effort" => nil })
    assert_response :ok
    assert_response_matches_contract
    assert_equal({ "model" => "", "effort" => "" }, response.parsed_body.fetch("result"))
    assert_equal [ "", "" ], @seat.reload.attributes.values_at("model", "effort")
  end

  test "unlisted model and effort are invalid and their messages give the accepted values" do
    [ [ @values.merge("model" => "made-up"), "claude-opus-5-5" ],
      [ @values.merge("effort" => "made-up"), "high" ] ].each do |values, allowed|
      assert_no_difference -> { Event.where(type: "seat.changed").count } do
        report(body: values)
        assert_response :unprocessable_entity
      end
      assert_response_matches_contract
      assert_equal "invalid", response.parsed_body.dig("error", "code")
      assert_includes response.body, allowed
      assert_equal [ "", "" ], @seat.reload.attributes.values_at("model", "effort")
    end
  end

  test "a Native seat is forbidden and a caller without a seat token is unauthenticated" do
    native = @scenario.seat(credential: @scenario.credential, model: "")
    report(seat: native)
    assert_response :conflict
    assert_response_matches_contract
    assert_equal "forbidden", response.parsed_body.dig("refusal", "code")
    assert_equal [ "", "" ], native.reload.attributes.values_at("model", "effort")

    report(token: @scenario.owner_token)
    assert_response :unauthorized
    assert_response_matches_contract
  end

  test "the key and both body fields are required" do
    report(key: nil)
    assert_response :bad_request
    assert_response_matches_contract

    report(body: @values.except("effort"), check_request: false)
    assert_response :unprocessable_entity
    assert_response_matches_contract
  end

  private

  def report(seat: @seat, token: @scenario.token_for(seat), body: @values, key: new_key, check_request: true)
    call("report_model", token: token, key: key, body: body, check_request: check_request)
  end
end
