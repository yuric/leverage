require "test_helper"

class ScenarioM5Test < ActiveSupport::TestCase
  setup { @scenario = Scenario.new }

  test "a project can have a budget and an ordered brief" do
    project = @scenario.project(budget: 12.5,
      brief: [ { kind: "decision", text: "Use the record." }, { kind: "lesson", text: "Keep examples small." } ])

    assert_equal 12.5, project.budget
    assert_equal 1, project.brief_version
    entries = BriefEntry.where(project_id: project.id).order(:position)
    assert_equal [ [ 1, "decision", "Use the record." ], [ 2, "lesson", "Keep examples small." ] ],
      entries.pluck(:position, :kind, :text)
    changes = Event.where(project_id: project.id, type: "brief.changed").order(:seq)
    assert_equal entries.pluck(:id), changes.pluck(:subject_id)
    assert_equal [ 1, 1 ], changes.pluck(:payload).pluck("brief_version")
  end

  test "a task contract records its outward actions in order" do
    task = @scenario.task(state: "ready", actions: [ { kind: "send", description: "Send the sample." }, { kind: "publish" } ])
    actions = Action.where(task_id: task.id).order(:position)

    assert_equal [ [ "send", "contracted" ], [ "publish", "contracted" ] ], actions.pluck(:kind, :state)
    assert_equal "Send the sample.", actions.first.description
    event = Event.find_by!(task_id: task.id, type: "task.contract_changed")
    assert_equal actions.pluck(:id), event.payload.fetch("added_action_ids")
  end

  test "outward actions can be built in every action state" do
    events_by_state = {
      "contracted" => [], "requested" => %w[action.requested],
      "approved" => %w[action.requested action.approved],
      "started" => %w[action.requested action.approved action.started],
      "stopped" => %w[action.requested action.stopped],
      "waived" => %w[action.requested action.waived],
      "revoked" => %w[action.requested action.revoked],
      "done" => %w[action.requested action.approved action.started action.reported_done]
    }
    assert_equal Leverage::Contract.list("action_states").sort, events_by_state.keys.sort
    events_by_state.each do |state, events|
      task = @scenario.finishing_task(holder: false, actions: [ { state: state } ])
      action = Action.find_by(task_id: task.id)

      assert_equal state, action&.state
      assert_equal events, Event.where(subject_kind: "action", subject_id: action.id).order(:seq).pluck(:type)
    end
  end

  test "a Finishing task remembers its builder with or without a fresh lease" do
    builder = @scenario.seat(strength_rank: 3)
    waiting = @scenario.finishing_task(builder: builder, holder: false, actions: [ { state: "requested" } ])
    held = @scenario.finishing_task(builder: builder, holder: true, actions: [ { state: "approved" } ])

    assert_equal 3, builder.strength_rank
    assert_equal [ "finishing", builder.id, nil, nil ],
      [ waiting.state, waiting.builder_seat_id, waiting.holder_seat_id, waiting.lease_due_at ]
    assert_equal [ "finishing", builder.id, builder.id ], [ held.state, held.builder_seat_id, held.holder_seat_id ]
    assert_operator held.lease_due_at, :>, Event.find_by!(task_id: held.id, type: "action.approved").at
    assert_equal builder.id, Event.find_by!(task_id: held.id, type: "action.approved").payload.fetch("lease_seat_id")
  end

  test "a question records each outcome and its author" do
    builder = @scenario.seat
    task = @scenario.task(state: "working", builder: builder)
    orch = @scenario.orchestrator
    events_by_outcome = {
      "open" => %w[question.asked], "passed_on" => %w[question.asked],
      "answered" => %w[question.asked question.answered],
      "overturned" => %w[question.asked question.answered question.overturned]
    }
    assert_equal Leverage::Contract.list("question_outcomes").sort, events_by_outcome.keys.sort
    events_by_outcome.each do |outcome, events|
      question = @scenario.question(task, outcome: outcome, answerer: orch, blocking: false)

      assert_equal [ outcome, builder.id, false ], [ question.outcome, question.asking_seat_id, question.blocking ]
      assert_equal events, Event.where(subject_kind: "question", subject_id: question.id).order(:seq).pluck(:type)
      if %w[answered overturned].include?(outcome)
        assert_equal [ "seat", orch.id, outcome == "overturned" ? "decision" : "record" ], [ question.answered_by_kind, question.answered_by_id, question.basis ]
        assert_operator question.answered_at, :>=, question.asked_at
      else
        assert_nil question.answer
        assert_nil question.answered_at
      end
      if outcome == "passed_on"
        item = InboxItem.find_by!(about_id: task.id, kind: "question_passed_on")
        assert_equal question.id, item.facts.fetch("question_id")
        assert_nil item.hold_id
      end
    end
  end

  test "a model check at the action hook names its action" do
    task = @scenario.finishing_task(actions: [ {} ])
    action = Action.find_by!(task_id: task.id)
    rule = @scenario.rule(hook: "action.requested")
    check = @scenario.rule_check(task, rule: rule, subject: action)

    payload = Event.find_by!(type: "check.queued", subject_id: check.id).payload
    assert_equal [ "action", action.id, action.id ], payload.values_at("subject_kind", "subject_id", "action_id")
  end

  test "every job kind can be queued and claimed by its contract role" do
    task = @scenario.task(state: "working")
    final_task = @scenario.finishing_task(actions: [ {} ])
    action = Action.find_by!(task_id: final_task.id)
    rule = @scenario.rule(hook: "action.requested")
    approval_check = @scenario.rule_check(final_task, rule: rule, subject: action)
    question = @scenario.question(task)
    check = @scenario.rule_check(task, rule: @scenario.rule)
    targets = { "contract_draft" => task, "approval" => approval_check, "question" => question, "rule_check" => check }

    Leverage::Contract.jobs.fetch("jobs").each do |definition|
      kind, role = definition.values_at("kind", "claimer_role")
      target = targets.fetch(kind)
      target_task = kind == "approval" ? final_task : task
      queued = @scenario.job(kind: kind, task: target_task, target: target)
      seat = @scenario.seat(role: role)
      claimed = @scenario.job(kind: kind, task: target_task, target: target, state: "claimed", seat: seat)

      assert_equal [ "queued", role, nil ], [ queued.state, queued.seat_role, queued.claimed_by_seat_id ], kind
      assert_equal [ "claimed", role, seat.id ], [ claimed.state, claimed.seat_role, claimed.claimed_by_seat_id ], kind
      assert_equal [ Leverage::EventLog.kind_of(target), target.id ], [ claimed.target_kind, claimed.target_id ], kind
      assert_equal %w[job.queued job.claimed], Event.where(subject_id: claimed.id).order(:seq).pluck(:type)
    end
  end
end
