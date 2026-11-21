require "test_helper"
require_relative "entries/jobs_support"

class NeedsYouFactsQuestionsTest < ActiveSupport::TestCase
  include JobsSupport

  setup do
    use_scenario
    @builder = scenario.seat
    @task = scenario.task(state: "working", builder: @builder)
  end

  test "a blocking question passed on to the owner opens a Needs you item on its hold" do
    item, question = ask_question(blocking: true)

    holds = task_holds.where(closed_at: nil)
    assert_equal [ "owner_question" ], holds.pluck(:reason)
    assert_equal holds.sole.id, item.hold_id
    assert_equal({ "question_id" => question.id }, item.facts)
  end

  test "a non-blocking question passed on to the owner opens a Needs you item without a hold" do
    item, question = ask_question(blocking: false)

    assert_empty task_holds
    assert_nil item.hold_id
    assert_equal({ "question_id" => question.id }, item.facts)
  end

  test "two access requests open two Needs you items and one grant resolves both" do
    [ "Read the example folder.", "Read the example index." ].each do |description|
      assert_completed(seat_command(@builder, "request_access", { "id" => @task.id, "description" => description }))
    end

    holds = task_holds.where(reason: "access", closed_at: nil)
    items = open_items("access_request")
    assert_equal 2, holds.count
    assert_equal [ "Read the example folder.", "Read the example index." ], holds.order(:opened_at).pluck(:detail)
    assert_nil @task.reload.lease_due_at
    assert_equal holds.ids.sort, items.pluck(:hold_id).sort
    items.each do |item|
      assert_equal({}, item.facts)
      assert_equal %w[mark_access_granted cancel], item.choices
      assert_opened(item)
    end
    item_ids = items.ids
    hold_ids = holds.ids

    events = events_written do
      assert_completed(owner_command("grant_access", { "id" => @task.id }))
    end

    assert_empty task_holds.where(id: hold_ids, closed_at: nil)
    assert @task.reload.lease_due_at
    assert @task.resume_pending_since
    resolved = InboxItem.where(workspace_id: scenario.workspace_id, id: item_ids, state: "resolved")
    assert_equal item_ids.sort, resolved.ids.sort
    assert_equal [ [ "owner", scenario.owner.id ] ], resolved.distinct.pluck(:resolved_by_kind, :resolved_by_id)
    resolutions = events.select { |event| event.type == "inbox.resolved" }
    assert_equal item_ids.sort, resolutions.map(&:subject_id).sort
    assert_equal [ { "choice" => "mark_access_granted" } ] * 2, resolutions.map(&:payload)
  end

  private

  def task_holds
    Hold.where(workspace_id: scenario.workspace_id, task_id: @task.id)
  end

  def open_items(kind)
    InboxItem.where(workspace_id: scenario.workspace_id, about_kind: "task", about_id: @task.id, kind: kind, state: "open")
  end

  def ask_question(blocking:)
    assert_completed(seat_command(@builder, "acknowledge_briefing", { "id" => @task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(@task, seat: @builder) }))
    assert_completed(seat_command(@builder, "ask_question", { "id" => @task.id, "text" => "Which sample comes first?",
      "assumption" => "Start with Sample A.", "blocking" => blocking }))

    items = open_items("question_passed_on")
    assert_equal 1, items.count
    item = items.sole
    question = Question.where(workspace_id: scenario.workspace_id, task_id: @task.id).sole
    assert_equal [ "passed_on", blocking ], [ question.outcome, question.blocking ]
    assert_equal [ "answer" ], item.choices
    assert_opened(item)
    [ item, question ]
  end

  def assert_opened(item)
    event = Event.find_by!(workspace_id: scenario.workspace_id, type: "inbox.opened", subject_id: item.id)
    assert_equal({ "kind" => item.kind }, event.payload)
  end
end
