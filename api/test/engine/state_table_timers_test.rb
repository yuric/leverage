require "test_helper"

# Test 3 (PRD L836) for the timers (milestone 2 plan WP5): for each of
# milestone 2's three timers and every task state, the state_machine.json
# row's move and events, or invalid_state where no row starts. A timer is
# run here as its own command, by the app, on the one task or review it
# names, with its lease past the due time. Milestone 3's two timers are in
# Transitions::Table::TIMERS too; their cases are in
# state_table_handoff_test.rb (credential_hold_release) and
# state_table_accounts_test.rb (seat_run_placement) (milestone 3 plan
# HT-2), and state_table_all_test.rb proves each is walked once.
class StateTableTimersTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  COMMANDS = %w[builder_lease_expiry review_lease_expiry command_key_retention].freeze

  test "the three are Table::TIMERS but milestone 3's two" do
    assert_equal COMMANDS, T::Table::TIMERS - %w[credential_hold_release seat_run_placement]
  end

  setup { @scenario = Scenario.new(lease_length_seconds: 600) }

  def timer(command, params)
    T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: nil, caller_id: nil,
      key: nil, request_hash: nil, params: params))
  end

  def last_seq = Workspace.find(@scenario.workspace_id).last_seq

  # A task in the case's state with a builder lease past its due time.
  def due_task(state)
    task = @scenario.task(state: state)
    task.update_columns(lease_due_at: @scenario.database_now - 1)
    task
  end

  # A review of a task in the case's state, held by a reviewer, past its
  # due time: the task's own review when it has one (In review, Done).
  def due_review(state)
    task = @scenario.task(state: state)
    review = Review.where(task_id: task.id).order(:round).last
    if state == "in_review"
      review = @scenario.review(task)
    elsif review.nil?
      review = Review.create!(workspace_id: @scenario.workspace_id, task_id: task.id, round: task.round,
        reviewer_seat_id: @scenario.seat(role: "reviewer").id)
    end
    @scenario.make_due(review)
  end

  StateTableCases.define(self, COMMANDS) do |kase|
    skip "Finishing needs an outward action, which milestone 2 does not build (SC-3)" if kase.from == "finishing"

    case kase.command
    when "builder_lease_expiry"
      task = due_task(kase.from)
      params = { "task_id" => task.id }
    when "review_lease_expiry"
      review = due_review(kase.from)
      task = Task.find(review.task_id)
      params = { "review_id" => review.id }
    when "command_key_retention"
      params = {}
    end
    before = last_seq
    outcome = timer(kase.command, params)
    written = Event.where(workspace_id: @scenario.workspace_id).where("seq > ?", before).order(:seq).map(&:type)

    if kase.invalid_state?
      assert outcome.refused?
      assert_equal kase.refusal, outcome.refusal.code
      assert_empty written
      assert_equal kase.from, task.reload.state
    else
      assert outcome.completed?, "#{kase.name}: #{outcome.refusal&.code}"
      assert_equal kase.events, written
      assert_equal kase.to, task.reload.state if kase.to
      if kase.builder_lease == "ends"
        assert_nil task.lease_due_at
        assert_nil task.holder_seat_id
      end
      assert_nil review.reload.reviewer_seat_id if kase.command == "review_lease_expiry"
    end
  end
end
