require "test_helper"

# Loading each decision, task and associated event is a set read even as
# the list grows. Capturing only SELECT statements avoids schema setup and
# transaction bookkeeping that vary with the connection.
class DecisionsQueryTest < CommittingTestCase
  test "the decision list does not issue one query per decision" do
    task = scenario.task(state: "working")
    seat = scenario.orchestrator
    scenario.question(task, outcome: "answered", basis: "decision", answerer: seat)
    small, baseline = read_with_select_count

    8.times do
      task = scenario.task(state: "working")
      scenario.question(task, outcome: "answered", basis: "decision", answerer: seat)
    end
    large, expanded = read_with_select_count

    assert_equal 1, small.fetch(:decisions).size
    assert_equal 9, large.fetch(:decisions).size
    assert_operator expanded, :<=, baseline, "the read must load tasks, questions and events together"
  end

  private

  def read_with_select_count
    count = 0
    callback = ->(*, payload) { count += 1 if payload[:name] != "SCHEMA" && payload[:sql].match?(/\ASELECT\b/i) }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      Leverage::Reads::Decisions.call(scenario.workspace_id)
    end
    [ result, count ]
  end
end
