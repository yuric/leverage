require "test_helper"

# Only the asking seat, while it still holds the task, reads a question
# (WP11, get_question). The HTTP layer marks a successful read.
class QuestionReadTest < CommittingTestCase
  include OpenapiAssertions

  test "the asking holder reads the current question and answer fields" do
    builder = scenario.seat(role: "builder")
    orchestrator = scenario.orchestrator
    task = scenario.task(state: "working", builder: builder)
    question = scenario.question(task, outcome: "answered", answerer: orchestrator, basis: "decision",
      assumption: "Use the first sample.")

    found = Leverage::Reads::Question.call(builder, question.id)

    assert_instance_of Leverage::Reads::Question::Found, found
    assert_equal question.id, found.row.id
    body = JSON.parse(JSON.generate(found.body))
    assert_empty contract_errors("#/components/schemas/Question", body)
    assert_equal [ question.id, task.id, builder.id, question.text, question.assumption, true ],
      body.values_at("id", "task_id", "asking_seat_id", "text", "assumption", "blocking")
    assert_equal [ "answered", question.answer, "decision", "seat", orchestrator.id, false ],
      body.values_at("outcome", "answer", "basis", "answered_by_kind", "answered_by_id", "overturned")
    assert_equal question.asked_at, Time.iso8601(body.fetch("asked_at"))
    assert_equal question.answered_at, Time.iso8601(body.fetch("answered_at"))
    assert_nil question.reload.read_at
  end

  test "an overturned answer is marked as overturned in the read" do
    builder = scenario.seat(role: "builder")
    task = scenario.task(state: "working", builder: builder)
    question = scenario.question(task, outcome: "overturned")

    found = Leverage::Reads::Question.call(builder, question.id)
    assert_instance_of Leverage::Reads::Question::Found, found
    body = JSON.parse(JSON.generate(found.body))

    assert_empty contract_errors("#/components/schemas/Question", body)
    assert_equal [ "overturned", true ], body.values_at("outcome", "overturned")
  end

  test "the asking builder must still be the current holder, including after submit" do
    asking = scenario.seat(role: "builder")
    other = scenario.seat(role: "builder")
    submitted = scenario.task(state: "in_review", builder: asking)
    asked_before_submit = scenario.question(submitted, outcome: "answered")
    assert_not_holder asking, asked_before_submit

    task = scenario.task(state: "working", builder: asking)
    question = scenario.question(task, outcome: "answered")
    assert_not_holder other, question

    task.update_columns(holder_seat_id: other.id)
    assert_not_holder asking, question
    assert_not_holder other, question
  end

  test "an expired lease does not let the asking seat read the answer" do
    builder = scenario.seat(role: "builder")
    task = scenario.task(state: "working", builder: builder)
    question = scenario.question(task, outcome: "answered")
    task.update_columns(lease_due_at: scenario.database_now - 10)

    assert_not_holder builder, question
  end

  test "a question in another workspace is absent" do
    builder = scenario.seat(role: "builder")
    elsewhere = Scenario.new
    question = elsewhere.question(elsewhere.task(state: "working"), outcome: "answered")

    assert_nil Leverage::Reads::Question.call(builder, question.id)
  end

  test "the question must belong to the task in the request path" do
    builder = scenario.seat(role: "builder")
    task = scenario.task(state: "working", builder: builder)
    other_task = scenario.task(state: "backlog")
    question = scenario.question(task, outcome: "answered")

    assert_nil Leverage::Reads::Question.call(builder, question.id, task_id: other_task.id)
  end

  private

  def assert_not_holder(seat, question)
    result = Leverage::Reads::Question.call(seat, question.id)
    assert_instance_of Leverage::Transitions::Refusal, result
    assert_equal "not_holder", result.code
  end
end
