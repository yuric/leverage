require "test_helper"
require_relative "jobs_support"

class ReportCostTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @builder = own_seat
    @task = scenario.task(state: "working", builder: @builder)
    @params = { "id" => @task.id, "tokens" => 0, "spend" => 0 }
  end

  test "a different builder cannot report cost on the holder's task" do
    events = events_written { assert_refused("not_holder", seat_command(own_seat, "report_cost", @params)) }

    assert_empty events
  end

  test "a seat outside the task's workspace cannot report its cost" do
    params = @params.merge("id" => Scenario.new.task.id)

    assert_raises(Leverage::Transitions::NotFound) { seat_command(@builder, "report_cost", params) }
  end
end
