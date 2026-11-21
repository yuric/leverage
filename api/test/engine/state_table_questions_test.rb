require "test_helper"
require_relative "entries/jobs_support"

class StateTableQuestionsTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario(lease_length_seconds: 600)
    @builder = own_seat
  end

  def task_in(state)
    if state == "finishing"
      scenario.finishing_task(builder: @builder, actions: [ { kind: "publish", description: "Publish the sample.", state: "approved" } ])
    else
      scenario.task(state: state, builder: @builder)
    end
  end

  def assert_row(kase)
    outcome = nil
    written = events_written { outcome = yield }
    if kase.refusal
      assert_refused(kase.refusal, outcome)
      assert_empty written
    else
      assert_completed(outcome)
      assert_equal kase.events, types(written).first(kase.events.size)
      allowed = kase.row.fetch("side_events").pluck("event")
      assert_empty types(written).drop(kase.events.size) - allowed
    end
    written
  end

  StateTableCases.define(self, %w[ask_question request_access grant_access]) do |kase|
    task = task_in(kase.from || "working")
    command = kase.command
    if command == "grant_access"
      scenario.hold(task, reason: "access")
      assert_row(kase) { owner_command(command, { "id" => task.id }) }
      assert_empty Leverage::Holds.open_holds(task)
    else
      if task.holder_seat_id == @builder.id
        briefing = Leverage::Briefing
        BriefingAcknowledgement.create!(workspace_id: task.workspace_id, seat_id: @builder.id, task_id: task.id,
          lease_event_id: briefing.lease_event(task, seat: @builder).id, briefing_hash: briefing.hash_for(task, seat: @builder),
          acknowledged_at: scenario.database_now) if command == "ask_question"
      elsif kase.invalid_state?
        # Exercise the unlisted state independently of the earlier holder refusal.
        task.update!(holder_seat_id: @builder.id)
      end
      params = if command == "ask_question"
        { "text" => "Which sample?", "assumption" => "The short one.", "blocking" => false }
      else
        { "description" => "Read the sample folder." }
      end
      assert_row(kase) { seat_command(@builder, command, params.merge("id" => task.id)) }
      assert_equal kase.from, task.reload.state
    end
  end

  %w[done cancelled].each do |state|
    test "an orchestrator's answer cannot be withdrawn or replaced after #{state}" do
      task = task_in(state)
      answered = scenario.question(task, outcome: "answered", basis: "decision", asking_seat: @builder)
      overturned = scenario.question(task, outcome: "overturned", basis: "decision", asking_seat: @builder)

      assert_empty events_written {
        assert_refused("invalid_state", owner_command("overturn_answer", { "id" => answered.id }))
        assert_refused("invalid_state", owner_command("answer_question", { "id" => overturned.id, "answer" => "Sample answer." }))
      }
      assert_equal "answered", answered.reload.outcome
      assert_equal "overturned", overturned.reload.outcome
    end
  end

  StateTableCases.define(self, %w[answer_question]) do |kase|
    task = task_in("working")
    outcomes = kase.refusal ? %w[open answered] : %w[passed_on overturned]
    outcomes.each do |outcome|
      question = scenario.question(task, outcome: outcome, blocking: false)
      written = assert_row(kase) { owner_command(kase.command, { "id" => question.id, "answer" => "The long sample." }) }
      if kase.refusal
        assert_equal outcome, question.reload.outcome
      else
        expected = outcome == "passed_on" ? %w[question.answered inbox.resolved] : %w[question.answered]
        assert_equal expected, types(written)
        assert_equal [ "answered", "The long sample.", "owner", "owner", scenario.owner.id ],
          question.reload.attributes.values_at("outcome", "answer", "basis", "answered_by_kind", "answered_by_id")
      end
    end
    assert_equal "working", task.reload.state
  end

  StateTableCases.define(self, %w[overturn_answer]) do |kase|
    task = task_in("working")
    if kase.refusal
      %w[open passed_on overturned answered].each do |outcome|
        answerer = scenario.owner if outcome == "answered"
        question = scenario.question(task, outcome: outcome, answerer: answerer, blocking: false)
        assert_row(kase) { owner_command(kase.command, { "id" => question.id }) }
        assert_equal outcome, question.reload.outcome
      end
    else
      %w[record decision].each do |basis|
        question = scenario.question(task, outcome: "answered", basis: basis)
        question.update!(read_at: scenario.database_now)
        assert_row(kase) { owner_command(kase.command, { "id" => question.id }) }
        assert_equal [ "overturned", basis, nil ], question.reload.attributes.values_at("outcome", "basis", "read_at")
        assert_empty Leverage::Holds.open_holds(task)
      end
    end
  end
end
