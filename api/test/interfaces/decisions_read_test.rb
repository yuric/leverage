require "test_helper"

# The owner sees decisions the orchestrator made alone (AP-31 to AP-35).
class DecisionsReadTest < CommittingTestCase
  include OpenapiAssertions

  test "the read lists only decisions and orchestrator approvals of its workspace, newest first" do
    task = scenario.task(state: "working")
    seat = scenario.orchestrator
    question = scenario.question(task, outcome: "answered", basis: "decision", answerer: seat)
    scenario.question(task, outcome: "answered", basis: "record", answerer: seat)
    scenario.question(task, outcome: "answered", answerer: scenario.owner)
    scenario.question(task, outcome: "passed_on", blocking: false)

    finishing = scenario.finishing_task(actions: [ { state: "approved" }, { state: "stopped" },
                                                    { description: "Publish the sample." } ])
    action = Action.where(task_id: finishing.id, state: "requested").sole
    decision = approve(finishing, action, seat)

    elsewhere = Scenario.new
    elsewhere.question(elsewhere.task(state: "working"), outcome: "answered", basis: "decision")

    rows = decisions
    assert_equal [ action.id, question.id ], rows.map { |row| row["action_id"] || row["question_id"] }
    approval, answer = rows
    assert_equal [ "approval", finishing.id, finishing.title, seat.id, nil, "approved", false, nil, nil, true ],
      approval.values_at(*%w[kind task_id task_title seat_id outcome action_state started overturned_at overturn_effect undoable])
    assert_equal action.description, approval.fetch("summary")
    assert_equal decision.at, Time.iso8601(approval.fetch("decided_at"))

    assert_equal [ "question", task.id, task.title, seat.id, question.text, question.answer, nil, false, nil, nil, true ],
      answer.values_at(*%w[kind task_id task_title seat_id summary outcome action_state started overturned_at overturn_effect undoable])
    assert_equal event_for(question, "question.answered").at, Time.iso8601(answer.fetch("decided_at"))
  end

  test "a withdrawn answer keeps its original decision attribution and reads the overturn from the log" do
    task = scenario.task(state: "working")
    seat = scenario.orchestrator
    question = scenario.question(task, outcome: "overturned", answerer: seat, basis: "decision")
    overturn = event_for(question, "question.overturned")

    question.update!(outcome: "answered", basis: "owner", answer: "Use the other sample.", answered_by_kind: "owner",
      answered_by_id: scenario.owner.id, answered_at: scenario.database_now)
    scenario.append("question.answered", task: task, subject: question, actor_kind: "owner", actor_id: scenario.owner.id,
      payload: { basis: "owner" })

    row = only_decision
    assert_equal [ question.id, seat.id, "answer_withdrawn", false ], row.values_at(*%w[question_id seat_id overturn_effect undoable])
    assert_equal overturn.at, Time.iso8601(row.fetch("overturned_at"))
    original = Event.where(subject_id: question.id, type: "question.answered", actor_kind: "seat").sole
    assert_equal original.at, Time.iso8601(row.fetch("decided_at"))
    assert_equal question.answer, row.fetch("outcome")
  end

  test "past decisions keep their attribution after the orchestrator changes role" do
    seat = scenario.orchestrator
    task = scenario.task(state: "working")
    question = scenario.question(task, outcome: "answered", basis: "decision", answerer: seat)
    finishing = scenario.finishing_task(actions: [ {} ])
    action = Action.where(task_id: finishing.id).sole
    approve(finishing, action, seat)

    seat.update!(role: "planner")

    assert_equal [ [ action.id, seat.id ], [ question.id, seat.id ] ],
      decisions.map { |row| [ row["action_id"] || row["question_id"], row["seat_id"] ] }
  end

  test "a decided question on a Done or Cancelled task stays listed and cannot be undone" do
    seat = scenario.orchestrator
    builder = scenario.seat(role: "builder")
    %w[done cancelled].each do |state|
      task = scenario.task(state: state, builder: builder)
      scenario.question(task, outcome: "answered", basis: "decision", asking_seat: builder, answerer: seat)
    end

    assert_equal [ false, false ], decisions.map { |row| row.fetch("undoable") }
  end

  test "a manual stop of an orchestrator approval is not an overturn" do
    task = scenario.finishing_task(actions: [ {} ])
    action = Action.where(task_id: task.id).sole
    approve(task, action, scenario.orchestrator)

    assert action_command("stop_action", action).completed?

    assert_equal [ "stopped", false, nil, nil ],
      only_decision.values_at("action_state", "undoable", "overturned_at", "overturn_effect")
    assert_equal({ "overturned" => false }, event_for(action, "action.stopped").payload)
  end

  test "overturn stops an action announced as started and retains the started mark" do
    task = scenario.finishing_task(actions: [ {} ])
    action = Action.where(task_id: task.id).sole
    approve(task, action, scenario.orchestrator)
    action.update!(state: "started")
    action_event("action.started", task, action, actor_kind: "seat", actor_id: task.builder_seat_id)

    assert_equal [ true, true ], only_decision.values_at("undoable", "started")

    assert action_command("overturn_approval", action).completed?
    stop = event_for(action, "action.stopped")

    row = only_decision
    assert_equal [ "stopped", true, false, "stopped" ], row.values_at("action_state", "started", "undoable", "overturn_effect")
    assert_equal stop.at, Time.iso8601(row.fetch("overturned_at"))
    assert_equal({ "overturned" => true }, stop.payload)
    repeat = action_command("overturn_approval", action)
    assert repeat.refused?
    assert_equal "invalid_state", repeat.refusal.code
    assert_equal stop.id, event_for(action, "action.stopped").id
  end

  test "overturning a completed action records the decision without making it undoable" do
    task = scenario.finishing_task(actions: [ {}, {} ])
    action = Action.where(task_id: task.id).order(:position).first
    approve(task, action, scenario.orchestrator)
    action.update!(state: "done")
    action_event("action.marked_done", task, action, actor_kind: "owner", actor_id: scenario.owner.id)

    assert_equal [ "done", false, nil ], only_decision.values_at("action_state", "undoable", "overturn_effect")

    event = action_event("action.overturn_recorded", task, action, actor_kind: "owner", actor_id: scenario.owner.id)
    row = only_decision
    assert_equal [ "done", false, false, "recorded_only" ], row.values_at("action_state", "started", "undoable", "overturn_effect")
    assert_equal event.at, Time.iso8601(row.fetch("overturned_at"))
  end

  test "a removed action definition leaves its original approval in the list" do
    task = scenario.finishing_task(actions: [ {} ])
    action = Action.where(task_id: task.id).sole
    granted = approve(task, action, scenario.orchestrator)
    action_event("action.withdrawn", task, action, actor_kind: "owner", actor_id: scenario.owner.id)
    action.destroy!

    rows = decisions
    assert_equal 1, rows.length
    row = rows.sole
    assert_equal [ action.id, granted.actor_id, nil, false ], row.values_at("action_id", "seat_id", "action_state", "undoable")
    assert_equal granted.at, Time.iso8601(row.fetch("decided_at"))
  end

  private

  def decisions
    body = JSON.parse(JSON.generate(Leverage::Reads::Decisions.call(scenario.workspace_id)))
    assert_empty contract_errors("#/components/schemas/DecisionsList", body)
    body.fetch("decisions")
  end

  def approve(task, action, seat)
    action.update!(state: "approved", approved_by_kind: "seat", approved_by_id: seat.id)
    action_event("action.approved", task, action, actor_kind: "seat", actor_id: seat.id,
      payload: { lease_seat_id: nil })
  end

  def action_command(command, action)
    transitions = Leverage::Transitions
    transitions.apply(transitions::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "owner",
      caller_id: scenario.owner.id, key: SecureRandom.uuid, request_hash: command, params: { "id" => action.id }))
  end

  def only_decision
    rows = decisions
    assert_equal 1, rows.size
    rows.first
  end

  # WP1's Scenario can record outward-action events before the matching
  # step rows are implemented. The append itself must still succeed.
  def action_event(type, task, action, **fields)
    ActiveRecord::Base.transaction do
      ctx = scenario.context
      ctx.emit(type, task: task, subject: action, **fields, command_id: nil)
    rescue Leverage::Steps::Unsupported
      Event.find_by!(workspace_id: scenario.workspace_id, seq: ctx.workspace.last_seq, type: type, subject_id: action.id)
    end
  end

  def event_for(row, type) = Event.where(subject_id: row.id, type: type).sole
end
