require "test_helper"

# The task page's milestone 4 fields (get_task; milestone 4 plan §2.3,
# RD-27, RD-28, RD-37, RD-45; PRD L269 to L306, L322, L898): the task's
# steps with their durations and its lifetime, its rule checklist with the
# version each check ran and what the owner may do with it, the command
# that waits, and where a contract draft stands. Each from the rows Scenario
# builds, read through Reads::TaskPage (a Snapshot: CommittingTestCase) and
# held to openapi.json's TaskPage.
class TaskPageReadTest < CommittingTestCase
  include OpenapiAssertions

  # rule_checks.overridden_by_user_id references users, and a committing
  # test leaves its rows behind: the tests that delete every user (those of
  # create_owner and the owner's session) would meet this test's overrides.
  # Clear the references it made.
  teardown { RuleCheck.where(workspace_id: scenario.workspace_id).update_all(overridden_by_user_id: nil) }

  def page(task)
    body = Leverage::Reads::TaskPage.call(scenario.workspace_id, task.id)
    json = JSON.parse(JSON.generate(body))
    assert_matches_component("TaskPage", json)
    json
  end

  # Microseconds since the epoch of an ISO 8601 time: whole numbers, so a
  # sum of durations is compared exactly.
  def usec(iso) = (Time.iso8601(iso).to_r * 1_000_000).to_i

  def working_task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))

  def holder(task) = Seat.find(task.holder_seat_id)

  def check_of(json, check) = json.fetch("rule_checks").find { |item| item["id"] == check.id }

  # --- steps and lifetime ------------------------------------------------------------------------------------------

  test "the steps are the task's step rows in order, they touch end to end, the open one is measured to as_of, and they sum to the lifetime exactly" do
    task = working_task

    json = page(task)

    rows = TaskStep.where(task_id: task.id).order(:opened_at, :id).to_a
    steps = json.fetch("steps")
    assert_equal rows.map(&:kind), steps.map { |step| step["kind"] }
    assert_equal %w[wait_contract wait_ready briefing], steps.map { |step| step["kind"] }
    assert_equal rows.map(&:step_class), steps.map { |step| step["step_class"] }
    assert_nil steps.last["closed_at"]
    steps.each_cons(2) { |before, after| assert_equal before["closed_at"], after["opened_at"] }
    as_of = usec(json.fetch("as_of"))
    durations = steps.map { |step| (step["closed_at"] ? usec(step["closed_at"]) : as_of) - usec(step["opened_at"]) }
    steps.zip(durations).each { |step, duration| assert_equal duration, (step["seconds"] * 1_000_000).round }
    assert_equal as_of - usec(steps.first["opened_at"]), durations.sum, "the steps cover the lifetime"
    assert_equal durations.sum, (json.fetch("lifetime_seconds") * 1_000_000).round
  end

  test "a done task's lifetime ends when it was done, whatever the time of the read" do
    task = scenario.task(state: "done")

    first = page(task)
    second = page(task)

    assert_not_equal first["as_of"], second["as_of"]
    assert_equal first["lifetime_seconds"], second["lifetime_seconds"]
    steps = first.fetch("steps")
    assert steps.all? { |step| step["closed_at"] }, "a done task has no open step"
    assert_equal usec(steps.last["closed_at"]) - usec(steps.first["opened_at"]), (first["lifetime_seconds"] * 1_000_000).round
  end

  test "an idea's time is a step of its own, listed first, and counted in the lifetime" do
    task = scenario.task(state: "imaginarium")

    json = page(task)

    assert_equal [ "idea" ], json["steps"].map { |step| step["kind"] }
    assert_equal json["steps"].sole["seconds"], json["lifetime_seconds"]
  end

  test "a step's round, subject, seat and cause are its row's" do
    task = working_task
    rule = scenario.rule
    row = TaskStep.where(task_id: task.id, closed_at: nil).sole
    row.update_columns(cause_kind: "rule", cause_rule_id: rule.id, subject_kind: "hold", subject_id: rule.id)

    step = page(task)["steps"].last

    assert_equal({ "kind" => "briefing", "step_class" => "working", "round" => 0, "subject_kind" => "hold",
                   "subject_id" => rule.id, "seat_id" => task.holder_seat_id, "cause_kind" => "rule",
                   "cause_rule_id" => rule.id }, step.slice(*%w[kind step_class round subject_kind subject_id seat_id cause_kind cause_rule_id]))
  end

  # --- the rule checklist ------------------------------------------------------------------------------------------

  test "the checklist has one line per check in order of creation, each with the version it ran: an earlier check keeps its own version's date after a Save" do
    rule = scenario.rule(name: "A made-up rule")
    task = working_task
    first = scenario.rule_check(task, rule: rule, result: "failed", reason: "Made-up reason one.")
    old = scenario.current_version(rule)
    saved = RuleVersion.create!(old.attributes.except("id", "created_at").merge("version" => 2, "name" => "A reworded rule",
      "created_at" => old.created_at + 600))
    rule.update!(current_version: 2)
    second = scenario.rule_check(task, rule: rule, result: "passed")

    checks = page(task).fetch("rule_checks")

    assert_equal [ first.id, second.id ], checks.map { |item| item["id"] }
    earlier, later = checks
    assert_equal({ "rule_id" => rule.id, "rule_name" => "A made-up rule", "rule_version_id" => old.id, "version" => 1,
                   "version_saved_at" => old.created_at.utc.iso8601(6), "hook" => "task.before_submit",
                   "moment_name" => "before work is submitted", "round" => 0, "checker" => "model", "on_fail" => "block",
                   "result" => "failed", "effect" => nil, "reason" => "Made-up reason one.", "overridden_at" => nil,
                   "overridden_by_user_id" => nil, "override_reason" => nil },
      earlier.except("id", "attempts", "queue_seconds", "run_seconds", "can_override", "can_rerun"))
    assert_equal [ saved.id, 2, "A reworded rule", saved.created_at.utc.iso8601(6) ],
      later.values_at("rule_version_id", "version", "rule_name", "version_saved_at")
  end

  test "each check lists its attempts in order, and its queue and run seconds are its last attempt's" do
    rule = scenario.rule
    task = working_task
    check = scenario.rule_check(task, rule: rule, result: "passed", attempts: 2)
    base = scenario.database_now.change(usec: 0) - 1000
    first, last = RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).to_a
    first.update_columns(queued_at: base, started_at: nil, finished_at: nil)
    last.update_columns(queued_at: base + 120, started_at: base + 150, finished_at: base + 195.5)
    queued = scenario.rule_check(task, rule: rule)

    json = page(task)

    item = check_of(json, check)
    assert_equal [ [ 1, base.utc.iso8601(6), nil, nil ], [ 2, (base + 120).utc.iso8601(6), (base + 150).utc.iso8601(6),
                                                          (base + 195.5).utc.iso8601(6) ] ],
      item["attempts"].map { |attempt| attempt.values_at("attempt_number", "queued_at", "started_at", "finished_at") }
    assert_equal [ 30, 45.5 ], item.values_at("queue_seconds", "run_seconds")
    assert_equal [ nil, nil ], check_of(json, queued).values_at("queue_seconds", "run_seconds"), "it has not started"
  end

  # The checklist's two buttons (RD-28): "Let it through once" on failed
  # and errored rows and on the row held at the re-run limit, "Run it
  # again" on errored rows; neither once the row is overridden, nor on a
  # row that passed, did not apply, was withdrawn or is still running, nor
  # on a policy's row or a warn rule's.
  test "can_override and can_rerun follow RD-28" do
    block = scenario.rule
    warn = scenario.rule(on_fail: "warn")
    policy = scenario.rule(key: "different_provider_review", origin: "shipped")
    task = working_task
    rows = {
      failed: scenario.rule_check(task, rule: block, result: "failed"),
      error: scenario.rule_check(task, rule: block, result: "error"),
      passed: scenario.rule_check(task, rule: block, result: "passed"),
      running: scenario.rule_check(task, rule: block),
      not_applicable: scenario.rule_check(task, rule: block, result: "not_applicable"),
      withdrawn: scenario.rule_check(task, rule: block, result: "withdrawn"),
      overridden_failed: scenario.rule_check(task, rule: block, result: "failed"),
      overridden_error: scenario.rule_check(task, rule: block, result: "error"),
      at_limit: scenario.rule_check(task, rule: block),
      warn_failed: scenario.rule_check(task, rule: warn, result: "failed"),
      applied: scenario.rule_check(task, rule: policy, result: "applied", effect: "refused", subject: scenario.seat(role: "reviewer"))
    }
    [ rows[:overridden_failed], rows[:overridden_error] ].each do |check|
      check.update_columns(overridden_at: scenario.database_now, overridden_by_user_id: scenario.owner.id,
        override_reason: "Made-up reason.")
    end
    scenario.hold(task, reason: "rerun_limit", item: false).update_columns(rule_id: block.id, rule_check_id: rows[:at_limit].id)

    json = page(task)

    expected = { failed: [ true, false ], error: [ true, true ], passed: [ false, false ], running: [ false, false ],
                 not_applicable: [ false, false ], withdrawn: [ false, false ], overridden_failed: [ false, false ],
                 overridden_error: [ false, false ], at_limit: [ true, false ], warn_failed: [ false, false ],
                 applied: [ false, false ] }
    actual = rows.transform_values { |check| check_of(json, check).values_at("can_override", "can_rerun") }
    assert_equal expected, actual
  end

  test "a cancelled or done task offers neither button" do
    rule = scenario.rule
    [ scenario.task(state: "done"), scenario.task(state: "cancelled") ].each do |task|
      failed = scenario.rule_check(task, rule: rule, result: "failed")
      errored = scenario.rule_check(task, rule: rule, result: "error")

      json = page(task)

      [ failed, errored ].each { |check| assert_equal [ false, false ], check_of(json, check).values_at("can_override", "can_rerun") }
    end
  end

  test "an overridden check carries who let it through, when and why" do
    rule = scenario.rule
    task = working_task
    check = scenario.rule_check(task, rule: rule, result: "failed", reason: "Made-up reason.")
    at = scenario.database_now.change(usec: 0)
    check.update_columns(overridden_at: at, overridden_by_user_id: scenario.owner.id, override_reason: "Made-up why.")

    item = check_of(page(task), check)

    assert_equal [ at.utc.iso8601(6), scenario.owner.id, "Made-up why." ],
      item.values_at("overridden_at", "overridden_by_user_id", "override_reason")
  end

  # --- the waiting command -----------------------------------------------------------------------------------------

  test "pending is null while no command waits, and a transition that ended is not waiting" do
    task = working_task
    assert_nil page(task)["pending"]

    scenario.pending_transition(task, command: "submit", requester: holder(task), state: "completed")
    assert_nil page(task)["pending"]
  end

  test "pending names the waiting command, since when, and the rules whose checks it still waits on" do
    running_rule = scenario.rule
    errored_rule = scenario.rule
    passed_rule = scenario.rule
    overridden_rule = scenario.rule
    task = working_task
    pending = scenario.pending_transition(task, command: "submit", requester: holder(task))
    scenario.rule_check(task, rule: running_rule, pending: pending)
    scenario.rule_check(task, rule: errored_rule, result: "error", pending: pending)
    scenario.rule_check(task, rule: passed_rule, result: "passed", pending: pending)
    scenario.rule_check(task, rule: overridden_rule, result: "error", pending: pending)
      .update_columns(overridden_at: scenario.database_now, overridden_by_user_id: scenario.owner.id)
    scenario.rule_check(task, rule: passed_rule)

    assert_equal({ "command" => "submit", "since" => pending.reload.created_at.utc.iso8601(6),
                   "waiting_on_rule_ids" => [ running_rule.id, errored_rule.id ] }, page(task)["pending"])
  end

  # --- the contract draft ------------------------------------------------------------------------------------------

  test "draft is none until one is asked, queued while its job waits, writing while a planner holds it" do
    task = scenario.task(state: "backlog")
    assert_equal "none", page(task)["draft"]

    job = scenario.job(kind: "contract_draft", task: task)
    assert_equal "queued", page(task)["draft"]

    job.update_columns(state: "claimed", claimed_by_seat_id: scenario.planner.id, claimed_at: scenario.database_now)
    assert_equal "writing", page(task)["draft"]
  end

  test "draft is not_written after the second miss while the task is in Backlog, and none once a draft was written or withdrawn" do
    task = scenario.task(state: "backlog")
    scenario.job(kind: "contract_draft", task: task, state: "timed_out")
    second = scenario.job(kind: "contract_draft", task: task, state: "timed_out", attempt_number: 2)
    assert_equal "not_written", page(task)["draft"]

    second.update_columns(state: "finished")
    assert_equal "none", page(task)["draft"]
    second.update_columns(state: "withdrawn")
    assert_equal "none", page(task)["draft"]

    ready = scenario.task(state: "ready")
    scenario.job(kind: "contract_draft", task: ready, state: "timed_out", attempt_number: 2)
    assert_equal "none", page(ready)["draft"], "the button is offered again only in Backlog (RD-37)"
  end

  test "another task's checks, transition and draft are not this page's" do
    task = working_task
    other = working_task
    rule = scenario.rule
    scenario.rule_check(other, rule: rule, result: "failed")
    scenario.pending_transition(other, command: "submit", requester: holder(other))
    scenario.job(kind: "contract_draft", task: other)

    json = page(task)

    assert_equal [], json["rule_checks"]
    assert_nil json["pending"]
    assert_equal "none", json["draft"]
  end
end
