require "test_helper"

# What Scenario builds for milestone 4's tests (milestone 4 plan WP1, RT-2,
# §0.1 fact 10): a workspace with no rule row unless a test asks; the
# shipped set; a custom rule and its versions; a rule check with its
# attempts and jobs; a job in each state; a pending transition with its
# request; the two job roles' seats; a golden trace's setup with its rules.
# Each builder inserts rows and appends the events that match them, as
# every other builder does, and no step changes for them yet (WP5's).
class ScenarioRulesTest < ActiveSupport::TestCase
  setup { @scenario = Scenario.new }

  def events(type) = Event.where(workspace_id: @scenario.workspace_id, type: type).order(:seq).to_a

  test "a workspace has no rule row unless a test asks (RT-2)" do
    @scenario.task(state: "done")
    assert_equal 0, Rule.where(workspace_id: @scenario.workspace_id).count
    assert_empty events("rule.created")
  end

  test "with_shipped_rules writes the seven, on, at version 1, each with rule.created by the owner" do
    rules = @scenario.with_shipped_rules(off: %w[specific_details])

    assert_equal Leverage::Rules::Shipped.all.map(&:key), rules.map(&:key)
    assert_equal [ false ], rules.reject(&:enabled).map(&:enabled)
    assert_equal "specific_details", rules.reject(&:enabled).sole.key
    created = events("rule.created")
    assert_equal rules.map(&:id), created.map(&:subject_id)
    created.zip(rules).each do |event, rule|
      version = @scenario.current_version(rule)
      assert_equal [ "owner", @scenario.owner.id, nil, "rule" ], [ event.actor_kind, event.actor_id, event.command_id, event.subject_kind ]
      assert_equal({ "rule_version_id" => version.id, "version" => 1, "enabled" => rule.enabled }, event.payload)
      assert_equal Leverage::Rules::Shipped.find(rule.key).version_fields.transform_keys(&:to_s),
        version.attributes.slice(*Leverage::Rules::Shipped.find(rule.key).version_fields.keys.map(&:to_s))
    end
  end

  test "a custom rule has the key custom_ and its id, and each later version writes rule.changed" do
    rule = @scenario.rule(hook: "task.before_submit", instruction: "Made-up instruction.", versions: 3)
    versions = RuleVersion.where(rule_id: rule.id).order(:version).to_a

    assert_equal "custom_#{rule.id}", rule.key
    assert_equal [ 1, 2, 3 ], versions.map(&:version)
    assert_equal 3, rule.current_version
    assert_equal versions.last, @scenario.current_version(rule)
    assert_equal [ [ "model", "orchestrator", "block", "builder", "custom", "owner" ] ],
      versions.map { |version| [ version.checker, version.checker_role, version.on_fail, version.route, version.origin, version.author_kind ] }.uniq
    assert_equal [ { "rule_version_id" => versions.first.id, "version" => 1, "enabled" => true } ], events("rule.created").map(&:payload)
    assert_equal versions.drop(1).map { |version| { "rule_version_id" => version.id, "version" => version.version } },
      events("rule.changed").map(&:payload)
  end

  test "a model rule check has one attempt and one job per attempt, the earlier ones timed out" do
    rule = @scenario.rule(hook: "task.before_ready")
    task = @scenario.task(state: "backlog")
    check = @scenario.rule_check(task, rule: rule, attempts: 2)
    attempts = RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).to_a
    jobs = Job.where(id: attempts.map(&:job_id)).index_by(&:id)

    assert_nil check.result
    assert_equal [ task.id, rule.id, @scenario.current_version(rule).id, "task.before_ready", 0 ],
      [ check.task_id, check.rule_id, check.rule_version_id, check.hook, check.round ]
    assert_equal [ 1, 2 ], attempts.map(&:attempt_number)
    assert_equal [ "timed_out", "queued" ], attempts.map { |attempt| jobs.fetch(attempt.job_id).state }
    assert_equal [ [ "rule_check", "rule_check", check.id, "orchestrator" ] ],
      jobs.values.map { |job| [ job.kind, job.target_kind, job.target_id, job.seat_role ] }.uniq
    assert_equal [ 1, 2 ], jobs.values.map(&:attempt_number).sort
    assert_equal %w[check.queued job.queued job.timed_out job.requeued check.queued],
      Event.where(task_id: task.id).where("type LIKE 'check.%' OR type LIKE 'job.%'").order(:seq).pluck(:type)
  end

  test "an app rule check is one finished attempt with its result and no job" do
    rule = @scenario.rule(hook: "task.before_ready", checker: "app", checker_function: "minimum_criteria_count",
      parameters: { "minimum_count" => 1 }, instruction: nil, checker_role: nil, route: "owner")
    task = @scenario.task(state: "backlog")
    check = @scenario.rule_check(task, rule: rule, result: "failed", reason: "Made-up reason.")
    attempt = RuleCheckAttempt.find_by!(rule_check_id: check.id)

    assert_equal [ "failed", "Made-up reason." ], [ check.result, check.reason ]
    assert_nil attempt.job_id
    assert_equal [ attempt.queued_at ] * 2, [ attempt.started_at, attempt.finished_at ]
    finished = events("check.finished").sole
    assert_equal [ "failed", check.input_hash ], finished.payload.values_at("result", "input_hash")
    refute_includes finished.payload.values, "Made-up reason.", "a reason is content, never in a payload"
  end

  test "a finished model check's last job is finished, and a started one's is claimed by its checker" do
    rule = @scenario.rule(hook: "task.before_submit")
    orchestrator = @scenario.orchestrator
    started = @scenario.rule_check(@scenario.task(state: "working"), rule: rule, started: true, checker: orchestrator)
    done = @scenario.rule_check(@scenario.task(state: "working"), rule: rule, result: "passed", checker: orchestrator)

    started_attempt = RuleCheckAttempt.find_by!(rule_check_id: started.id)
    done_attempt = RuleCheckAttempt.find_by!(rule_check_id: done.id)
    assert_equal [ "claimed", orchestrator.id ], Job.find(started_attempt.job_id).then { |job| [ job.state, job.claimed_by_seat_id ] }
    assert_equal [ orchestrator.id, nil ], [ started_attempt.checker_seat_id, started_attempt.finished_at ]
    refute_nil started_attempt.started_at
    assert_equal "finished", Job.find(done_attempt.job_id).state
    refute_nil done_attempt.finished_at
  end

  test "a job can be built in each state, with its events" do
    task = @scenario.task(state: "backlog")
    planner = @scenario.planner
    Leverage::Contract.list("job_states").each do |state|
      job = @scenario.job(kind: "contract_draft", task: task, state: state, seat: (planner unless state == "queued"))

      assert_equal [ state, "contract_draft", "task", task.id, "planner", 1 ],
        [ job.state, job.kind, job.target_kind, job.target_id, job.seat_role, job.attempt_number ], state
      assert_equal state != "queued", !job.claimed_at.nil?, state if %w[queued claimed finished].include?(state)
    end
    assert_equal 5, events("job.queued").size
    assert_equal [ planner.id ], events("job.claimed").map(&:actor_id).uniq
  end

  test "a pending transition keeps its requester, key, frozen versions and request" do
    task = @scenario.task(state: "working")
    builder = Seat.find(task.holder_seat_id)
    version = @scenario.current_version(@scenario.rule(hook: "task.before_submit"))
    pending = @scenario.pending_transition(task, command: "submit", requester: builder, key: "k-submit",
      params: { "handoff_note" => "Made-up note." }, frozen_rule_version_ids: [ version.id ])

    assert_equal [ task.id, "submit", "k-submit", "seat", builder.id, [ version.id ], "pending",
                   { "handoff_note" => "Made-up note." } ],
      pending.attributes.values_at("task_id", "command", "command_key", "requester_kind", "requester_id",
        "frozen_rule_version_ids", "state", "params")
    owner_pending = @scenario.pending_transition(@scenario.task(state: "backlog"), command: "complete_contract",
      requester: @scenario.owner)
    assert_equal [ "owner", @scenario.owner.id ], [ owner_pending.requester_kind, owner_pending.requester_id ]
  end

  test "an orchestrator and a planner are seats of their roles" do
    assert_equal %w[orchestrator planner], [ @scenario.orchestrator.role, @scenario.planner.role ]
  end

  test "seed inserts a golden trace's rules with their ids, before the seats" do
    binder = Leverage::Contract::TraceBinder.new(start: Time.utc(2026, 1, 1))
    setup = binder.bind(Leverage::Contract.trace("07-pending-gate-check-error-override")).fetch("setup")
    @scenario.seed(setup)

    rules = Rule.where(workspace_id: @scenario.workspace_id).index_by(&:id)
    setup.fetch("rules").each do |row|
      rule = rules.fetch(row.fetch("id"))
      assert_equal row.values_at("key", "enabled", "current_version"), [ rule.key, rule.enabled, rule.current_version ]
      assert_equal row.fetch("current_version_id"), @scenario.current_version(rule).id
    end
    created = events("rule.created")
    assert_equal 7, created.size
    assert_operator created.map(&:seq).max, :<, events("seat.connected").map(&:seq).min
  end

  test "seed takes a custom rule's version fields from the setup, and refuses one with none" do
    binder = Leverage::Contract::TraceBinder.new(start: Time.utc(2026, 1, 1))
    setup = binder.bind(Leverage::Contract.trace("07-pending-gate-check-error-override")).fetch("setup")
    custom = { "id" => SecureRandom.uuid, "key" => "custom_made_up", "origin" => "custom", "enabled" => true,
               "current_version" => 1, "current_version_id" => SecureRandom.uuid, "name" => "A made-up rule",
               "hook" => "task.before_submit", "kind" => "gate", "checker" => "model",
               "scope" => { "kind" => "all_tasks", "values" => [] }, "instruction" => "Made-up instruction.",
               "on_fail" => "warn", "route" => "builder" }
    @scenario.seed(setup.merge("rules" => [ custom ]))
    version = RuleVersion.find(custom.fetch("current_version_id"))

    assert_equal [ "A made-up rule", "task.before_submit", "warn", "orchestrator", "custom" ],
      [ version.name, version.hook, version.on_fail, version.checker_role, version.origin ]
    bare = custom.slice("id", "key", "origin", "enabled", "current_version", "current_version_id")
      .merge("id" => SecureRandom.uuid, "key" => "custom_bare")
    assert_raises(ArgumentError) { Scenario.new.seed(setup.merge("rules" => [ bare ])) }
  end
end
