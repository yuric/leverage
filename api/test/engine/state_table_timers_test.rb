require "test_helper"
require_relative "entries/job_timers_support"

# Test 3 (PRD L836) for the timers (milestone 2 plan WP5): for each of
# milestone 2's three timers and every task state, the state_machine.json
# row's move and events, or invalid_state where no row starts. A timer is
# run here as its own command, by the app, on the one task or review it
# names, with its lease past the due time. Milestone 3's two timers are in
# Transitions::Table::TIMERS too; their cases are in
# state_table_handoff_test.rb (credential_hold_release) and
# state_table_accounts_test.rb (seat_run_placement) (milestone 3 plan
# HT-2), and state_table_all_test.rb proves each is walked once.
#
# Milestone 4 (its plan WP7, RT-5): the four job timers and
# orchestrator_offline, row by row. Their rows read no task state (from:
# null): one case per row, the guard first_miss or second_miss saying which
# miss it is. The writers they call are other packages' (WP4, WP6), so the
# events here come from JobTimersSupport's stand-ins, which write what the
# rows name: these cases prove which writers each row calls, and the whole
# table with the real writers is WP13's. reviewer_eligibility is WP9's.
class StateTableTimersTest < ActiveSupport::TestCase
  include JobTimersSupport

  T = Leverage::Transitions

  COMMANDS = %w[builder_lease_expiry review_lease_expiry command_key_retention].freeze

  test "the three are Table::TIMERS but milestone 3's two" do
    assert_equal COMMANDS, T::Table::TIMERS - %w[credential_hold_release seat_run_placement]
  end

  setup { @scenario = Scenario.new(lease_length_seconds: 600) }

  def scenario = @scenario

  def timer(command, params = {})
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

  # --- milestone 4 -------------------------------------------------------------

  JOB_TIMERS = %w[check_queue_timeout check_run_timeout contract_draft_job_queue_timeout
                  contract_draft_job_run_timeout].freeze
  NEW_COMMANDS = (JOB_TIMERS + %w[orchestrator_offline]).freeze

  test "milestone 4's timers are the pending TIMERS group but WP9's reviewer_eligibility" do
    assert_equal NEW_COMMANDS, T::Table::PENDING_GROUPS.fetch("TIMERS") - %w[reviewer_eligibility]
  end

  # The job a row's case times out, at its due time: a check's attempt (the
  # first, or the second after a first miss) or a draft's job.
  def due_job(command, second_miss)
    case command
    when "check_queue_timeout", "check_run_timeout"
      run = command == "check_run_timeout"
      _task, check, = pending_check(attempts: second_miss ? 2 : 1, started: run)
      run ? make_run_due(check) : make_queue_due(check)
      job_of(check)
    else
      run = command == "contract_draft_job_run_timeout"
      job = @scenario.job(kind: "contract_draft", task: @scenario.task(state: "backlog"), state: run ? "claimed" : "queued",
        seat: (@scenario.planner if run), attempt_number: second_miss ? 2 : 1)
      make_job_due(job, run ? :run : :queue)
      job
    end
  end

  def side_events(kase) = kase.row.fetch("side_events").map { |side| side.fetch("event") }

  StateTableCases.define(self, NEW_COMMANDS) do |kase|
    if kase.command == "orchestrator_offline"
      orchestrator_polled(600)
      _task, check, = pending_check
      make_queue_due(check)
      before = last_seq
      outcome = nil
      with_writers { outcome = timer(kase.command) }
      written = events_after(before).map(&:type)

      assert outcome.completed?
      assert_equal %w[inbox.opened], written, "no event of its own: the item opens as a side event"
      assert_empty written - side_events(kase)
    else
      job = due_job(kase.command, kase.guard == %w[second_miss])
      before = last_seq
      outcome = nil
      with_writers { outcome = timer(kase.command, "job_id" => job.id) }
      written = events_after(before).map(&:type)

      assert outcome.completed?, "#{kase.name}: #{outcome.refusal&.code}"
      assert_equal kase.events, written.first(kase.events.size)
      assert_empty written.drop(kase.events.size) - side_events(kase), "#{kase.name}: only the row's side events follow"
      assert_equal "timed_out", job.reload.state
    end
  end
end
