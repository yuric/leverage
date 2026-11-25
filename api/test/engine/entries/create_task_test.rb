require "test_helper"
require_relative "gated_flow_support"

class CreateTaskTest < ActiveSupport::TestCase
  include GatedFlowSupport

  setup do
    use_scenario
    @seat = scenario.seat(role: "reviewer")
    @body = contract_body.slice("title", "details", "criteria")
  end

  test "the creator is the actor in Backlog, on the completed contract and in Ready" do
    events = events_written do
      answer = assert_completed(seat_command(@seat, "add_task", @body))
      task = Task.find(answer.result.fetch("task_id"))
      assert_equal({ "task_id" => task.id, "state" => "ready" }, answer.result)
    end
    assert_equal %w[task.created task.contract_changed task.ready], events.map(&:type)
    assert events.all? { |event| event.actor_kind == "seat" && event.actor_id == @seat.id }
  end

  test "Create off refuses the command without creating a task" do
    @seat.update!(may_create: false)
    assert_no_difference("Task.count") { assert_refused "forbidden", seat_command(@seat, "add_task", @body) }
  end

  test "a removed seat cannot create a task at the transition boundary" do
    assert_completed(owner_command("remove_seat", { "id" => @seat.id }))
    assert_no_difference("Task.count") do
      assert_raises(T::NotFound) { seat_command(@seat, "add_task", @body) }
    end
  end

  test "failed app check leaves a contract for the owner to complete" do
    rule = scenario.rule(hook: "task.before_ready", checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => 4 })
    answer = assert_completed(seat_command(@seat, "add_task", @body))
    task = Task.find(answer.result.fetch("task_id"))
    assert_equal({ "task_id" => task.id, "state" => "backlog" }, answer.result)
    assert_equal [ "contract_incomplete" ], open_holds(task).map(&:reason)
    item = open_items(task).sole
    assert_equal [ "agent_task_incomplete", { "seat_id" => @seat.id } ], [ item.kind, item.facts ]
    assert_completed(owner_command("disable_rule", { "id" => rule.id }))
    events = events_written { assert_completed(owner_command("complete_contract", contract_body.merge("id" => task.id))) }
    assert_equal "resolved", item.reload.state
    assert_equal "ready", task.reload.state
    resolved = events.select { |event| event.type == "inbox.resolved" }.sole
    assert_equal [ item.id, "owner", { "choice" => "complete_contract" } ],
      [ resolved.subject_id, resolved.actor_kind, resolved.payload ]
  end

  test "a planner's draft the owner asked for resolves the item with the owner's choice" do
    rule = scenario.rule(hook: "task.before_ready", checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => 4 })
    task = Task.find(assert_completed(seat_command(@seat, "add_task", @body)).result.fetch("task_id"))
    item = open_items(task).sole
    planner = scenario.planner
    assert_completed(owner_command("draft_contract", { "id" => task.id }))
    assert_equal "open", item.reload.state
    assert_completed(owner_command("disable_rule", { "id" => rule.id }))
    job = Job.find(assert_completed(claim_job(planner)).result.fetch("job_id"))
    events = events_written { assert_completed(submit_result(planner, job, contract_body)) }

    assert_equal "ready", task.reload.state
    resolved = events.select { |event| event.type == "inbox.resolved" }.sole
    assert_equal [ item.id, "seat", planner.id, { "choice" => "draft_contract" } ],
      [ resolved.subject_id, resolved.actor_kind, resolved.actor_id, resolved.payload ]
  end

  test "an owner's own task that failed its check has no item, and its completion writes no choice" do
    rule = scenario.rule(hook: "task.before_ready", checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => 4 })
    task = scenario.task(state: "backlog", criteria: [])
    assert_completed(owner_command("complete_contract", contract_body.merge("id" => task.id)))
    assert_equal [ "contract_incomplete" ], open_holds(task).map(&:reason)
    assert_empty open_items(task)
    assert_completed(owner_command("disable_rule", { "id" => rule.id }))
    events = events_written { assert_completed(owner_command("complete_contract", contract_body.merge("id" => task.id))) }
    assert_includes events.map(&:type), "hold.closed"
    assert_empty events.select { |event| event.type == "inbox.resolved" }
  end

  test "the seat that added a task is not given its ready check, which another orchestrator answers" do
    creator = scenario.seat(role: "general")
    orchestrator = online_orchestrator
    model_rule
    assert_equal :pending, seat_command(creator, "add_task", @body).outcome
    task = Task.find(Event.find_by!(type: "task.created", actor_id: creator.id).task_id)
    assert_equal "backlog", task.state

    assert_refused "not_eligible", claim_job(creator)
    assert_equal "none", Leverage::Reads::NextItem.call(creator).fetch("kind")
    job = answer_next(orchestrator, PASSED)
    assert_equal [ task.id, orchestrator.id ], [ job.task_id, job.reload.claimed_by_seat_id ]
    assert_equal "ready", task.reload.state
  end

  test "the idle creator may choose a project, but a holder whose work has none cannot" do
    project = scenario.project
    id = assert_completed(seat_command(@seat, "add_task", @body.merge("project_id" => project.id))).result.fetch("task_id")
    assert_equal project.id, Task.find(id).project_id
    scenario.review(scenario.task(state: "in_review"), reviewer: @seat)
    assert_raises(T::Invalid) { seat_command(@seat, "add_task", @body.merge("project_id" => project.id)) }
    id = assert_completed(seat_command(@seat, "add_task", @body)).result.fetch("task_id")
    assert_nil Task.find(id).project_id
  end

  test "a task added in a paused project is held" do
    project = scenario.project
    assert_completed(owner_command("pause_project", { "id" => project.id }))
    answer = assert_completed(seat_command(@seat, "add_task", @body.merge("project_id" => project.id)))
    task = Task.find(answer.result.fetch("task_id"))
    assert_equal project.id, task.project_id
    assert_includes open_holds(task).map(&:reason), "project_paused"

    owner = assert_completed(owner_command("add_task", { "title" => "An owner's task", "project_id" => project.id }))
    owner_task_id = owner.result.fetch("task_id")
    creation = Event.find_by!(task_id: owner_task_id, type: "task.created")
    assert TaskStep.exists?(task_id: owner_task_id, kind: "wait_contract", opening_event_id: creation.id)
  end

  %w[task review job].each do |kind|
    test "a creator holding a #{kind} inherits its project and cannot name another" do
      project = scenario.project
      case kind
      when "task" then scenario.task(state: "working", project: project, builder: @seat)
      when "review" then scenario.review(scenario.task(state: "in_review", project: project), reviewer: @seat)
      when "job" then scenario.job(kind: "contract_draft", task: scenario.task(project: project), state: "claimed", seat: @seat)
      end
      answer = assert_completed(seat_command(@seat, "add_task", @body.merge("project_id" => nil)))
      assert_equal project.id, Task.find(answer.result.fetch("task_id")).project_id
      other = scenario.project(name: "Another project")
      assert_no_difference("Task.count") do
        assert_raises(T::Invalid) { seat_command(@seat, "add_task", @body.merge("project_id" => other.id)) }
      end
    end
  end
end
