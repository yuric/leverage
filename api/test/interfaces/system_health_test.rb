require "test_helper"

# The health line's milestone 4 half (get_system_health; milestone 4 plan
# §2.3, RD-17, RD-18): whether the agent that checks tasks is set up and
# online, and how many checks wait for it. Whether an orchestrator is
# online is RolePresence's (WP7); here a double answers it and records what
# it was asked. Read through Reads::SystemHealth (a Snapshot:
# CommittingTestCase) and held to openapi.json's SystemHealth.
class SystemHealthReadTest < CommittingTestCase
  include OpenapiAssertions

  # RolePresence's answer, with the calls it was asked.
  class Presence
    attr_reader :asked

    def initialize(online)
      @online = online
      @asked = []
    end

    def online?(workspace, role, at)
      @asked << [ workspace, role, at ]
      @online
    end
  end

  def health(presence: Presence.new(true), workspace_id: scenario.workspace_id)
    body = Leverage::Reads::SystemHealth.with_collaborators(presence: presence) do
      Leverage::Reads::SystemHealth.call(workspace_id)
    end
    json = JSON.parse(JSON.generate(body))
    assert_matches_component("SystemHealth", json)
    json
  end

  def working_task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))

  # --- orchestrator ---------------------------------------------------------------------------------------------

  test "the orchestrator is not_set_up while no enabled orchestrator seat exists, and RolePresence is not asked" do
    presence = Presence.new(true)
    assert_equal "not_set_up", health(presence: presence)["orchestrator"]

    scenario.seat(role: "builder")
    scenario.planner
    scenario.orchestrator(enabled: false)
    scenario.remove(scenario.orchestrator)
    assert_equal "not_set_up", health(presence: presence)["orchestrator"]
    assert_empty presence.asked
  end

  test "with an enabled orchestrator seat it is online or offline as RolePresence says, asked for the workspace, the role and the database's now" do
    scenario.orchestrator
    online = Presence.new(true)
    offline = Presence.new(false)

    assert_equal "online", health(presence: online)["orchestrator"]
    assert_equal "offline", health(presence: offline)["orchestrator"]

    workspace, role, at = online.asked.sole
    assert_equal scenario.workspace_id, workspace.id
    assert_kind_of Workspace, workspace
    assert_equal "orchestrator", role
    assert_in_delta scenario.database_now.to_f, at.to_f, 5
  end

  test "a paused orchestrator is still set up: RolePresence says whether it is online" do
    scenario.pause_seat(scenario.orchestrator)

    assert_equal "offline", health(presence: Presence.new(false))["orchestrator"]
  end

  # --- waiting checks -------------------------------------------------------------------------------------------

  test "waiting_checks counts the rule checks queued and not claimed and those held with check_error, each once" do
    rule = scenario.rule
    task = working_task
    scenario.rule_check(task, rule: rule)
    scenario.rule_check(task, rule: rule)
    scenario.rule_check(task, rule: rule, started: true)
    scenario.rule_check(task, rule: rule, result: "passed")
    errored = scenario.rule_check(task, rule: rule, result: "error")
    requeued = scenario.rule_check(scenario.task(state: "ready"), rule: rule)
    scenario.job(kind: "contract_draft", task: scenario.task(state: "backlog"))
    held = scenario.hold(task, reason: "check_error", item: false)
    held.update_columns(rule_id: rule.id, rule_check_id: errored.id)
    both = scenario.hold(Task.find(requeued.task_id), reason: "check_error", item: false)
    both.update_columns(rule_id: rule.id, rule_check_id: requeued.id)

    assert_equal 2 + 1 + 1, health["waiting_checks"]
  end

  test "a closed check_error hold, and another workspace's checks, are not waiting" do
    rule = scenario.rule
    task = working_task
    errored = scenario.rule_check(task, rule: rule, result: "error")
    hold = scenario.hold(task, reason: "check_error", item: false)
    hold.update_columns(rule_id: rule.id, rule_check_id: errored.id)
    ActiveRecord::Base.transaction { Leverage::Holds.close(scenario.context, hold: hold, task: task) }
    elsewhere = Scenario.new
    elsewhere.rule_check(elsewhere.task(state: "working", builder: elsewhere.seat(role: "builder")), rule: elsewhere.rule)

    assert_equal 0, health["waiting_checks"]
  end

  test "the health line's earlier fields are unchanged" do
    scenario.task(state: "ready")

    json = health

    assert_equal 1, json["ready_tasks"]
    assert_equal true, json["sweep_late"]
    assert_equal 0, json["waiting_reviews"]
  end
end
