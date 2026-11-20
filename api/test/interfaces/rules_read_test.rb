require "test_helper"

# list_rules (Settings, Rules; milestone 4 plan §2.3, RD-8, RD-26, RD-62)
# and the timing questions of PRD L315 to L318 (Reads::RuleTiming and the
# rake task leverage:rule_timing), each read from the rows Scenario builds.
# What a rule's version says in one sentence and whether it acts are the
# rules engine's (WP3's Rules::Sentences and Rules::AppCheckers); here they
# are scripted by a double, so this file tests the read and not the engine.
# Each read runs in Reads::Snapshot, which cannot be opened inside a test's
# own transaction: these are CommittingTestCases.
class RulesReadTest < CommittingTestCase
  include OpenapiAssertions

  # rule_checks.overridden_by_user_id references users, and a committing
  # test leaves its rows behind: the tests that delete every user (those of
  # create_owner and the owner's session) would meet this test's overrides.
  # Clear the references it made.
  teardown { RuleCheck.where(workspace_id: scenario.workspace_id).update_all(overridden_by_user_id: nil) }

  # The engine's two answers about a version, with the calls it was asked.
  class Words
    attr_reader :asked

    def initialize(idle: [])
      @idle = idle
      @asked = []
    end

    def sentence(version)
      @asked << [ :sentence, version.id ]
      "Made-up sentence of #{version.key}."
    end

    def acts?(version)
      @asked << [ :acts, version.id ]
      !@idle.include?(version.key)
    end
  end

  def read(words: Words.new, workspace_id: scenario.workspace_id)
    body = Leverage::Reads::Rules.with_collaborators(words: words) { Leverage::Reads::Rules.call(workspace_id) }
    json = JSON.parse(JSON.generate(body))
    assert_matches_component("RulesList", json)
    json
  end

  def entry(body, rule) = body.fetch("rules").find { |candidate| candidate.dig("rule", "id") == rule.id }

  def t0 = @t0 ||= scenario.database_now.change(usec: 0) - 3600

  # Puts the check's last attempt at the given times, seconds after t0.
  def times(check, queued:, started: nil, finished: nil)
    attempt = RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last
    attempt.update_columns(queued_at: t0 + queued, started_at: started && t0 + started, finished_at: finished && t0 + finished)
    attempt
  end

  def job_of(check) = Job.find(RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last.job_id)

  def working_task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))

  test "every rule that is not removed is listed, the shipped ones in their order, then the custom ones as they were added" do
    shipped = scenario.with_shipped_rules(off: %w[project_budget_pause])
    first = scenario.rule(name: "First made-up rule")
    second = scenario.rule(name: "Second made-up rule", hook: "task.before_claim")
    second.update_columns(created_at: first.created_at + 1)
    gone = scenario.rule(name: "Removed made-up rule")
    gone.update_columns(removed_at: scenario.database_now)

    body = read

    assert_equal shipped.map(&:key) + [ first.key, second.key ], body["rules"].map { |item| item.dig("rule", "key") }
    body["rules"].each do |item|
      rule = Rule.find(item.dig("rule", "id"))
      assert_equal({ "id" => rule.id, "key" => rule.key, "enabled" => rule.enabled, "current_version" => 1 }, item["rule"])
    end
    assert_equal [ "project_budget_pause" ], body["rules"].reject { |item| item.dig("rule", "enabled") }.map { |item| item.dig("rule", "key") }
  end

  test "each rule carries its current version as the contract shapes it: after a Save, the new one" do
    rule = scenario.rule(name: "A made-up rule", versions: 2, scope_kind: "checker_decides", route: "orchestrator",
      queue_timeout_seconds: 90, run_timeout_seconds: 200)
    current = scenario.current_version(rule)

    item = read["rules"].sole

    assert_equal 2, item.dig("rule", "current_version")
    version = item.fetch("version")
    assert_equal current.id, version["id"]
    assert_equal({ "rule_id" => rule.id, "version" => 2, "key" => rule.key, "name" => "A made-up rule",
                   "hook" => "task.before_submit", "kind" => "gate", "checker" => "model", "on_fail" => "block",
                   "route" => "orchestrator", "queue_timeout_seconds" => 90, "run_timeout_seconds" => 200,
                   "instruction" => current.instruction, "parameters" => {}, "origin" => "custom",
                   "author_kind" => "owner", "author_id" => scenario.owner.id },
      version.except("id", "scope", "created_at"))
    assert_equal({ "kind" => "checker_decides", "project_ids" => nil, "action_kinds" => nil }, version["scope"])
    assert_equal current.created_at.utc.iso8601(6), version["created_at"]
  end

  test "a rule's moment is its hook's moment name; an app rule has the engine's sentence and a model rule none; acts is the engine's" do
    rules = scenario.with_shipped_rules.index_by(&:key)
    idle = %w[ask_orchestrator_first escalate_after_failed_reviews project_budget_pause orchestrator_approves_actions]
    words = Words.new(idle: idle)

    body = read(words: words)

    by_key = body["rules"].index_by { |item| item.dig("rule", "key") }
    assert_equal "when a task is ready to start", by_key.fetch("acceptance_criteria")["moment_name"]
    assert_equal "when a reviewer claims a review", by_key.fetch("different_provider_review")["moment_name"]
    assert_equal "before anything goes out", by_key.fetch("orchestrator_approves_actions")["moment_name"]
    assert_equal "Made-up sentence of acceptance_criteria.", by_key.fetch("acceptance_criteria")["sentence"]
    assert_equal "Made-up sentence of escalate_after_failed_reviews.", by_key.fetch("escalate_after_failed_reviews")["sentence"]
    assert_nil by_key.fetch("specific_details")["sentence"], "a model rule's text is its instruction (L344)"
    assert_nil by_key.fetch("orchestrator_approves_actions")["sentence"]
    assert_equal idle.sort, by_key.reject { |_, item| item["acts"] }.keys.sort
    model_versions = %w[specific_details orchestrator_approves_actions].map { |key| scenario.current_version(rules.fetch(key)).id }
    assert_empty words.asked.select { |call, id| call == :sentence && model_versions.include?(id) }
  end

  test "a rule's stats: checks are its rows but not_applicable and withdrawn, overrides the rows let through, average the queue plus run of its finished attempts, tokens and spend its jobs'" do
    rule = scenario.rule
    other = scenario.rule
    task = working_task
    passed = scenario.rule_check(task, rule: rule, result: "passed", reason: "Made-up reason.")
    failed = scenario.rule_check(task, rule: rule, result: "failed", reason: "Made-up reason.")
    failed.update_columns(overridden_at: scenario.database_now, overridden_by_user_id: scenario.owner.id,
      override_reason: "Made-up reason.")
    running = scenario.rule_check(task, rule: rule)
    skipped = scenario.rule_check(task, rule: rule, result: "not_applicable")
    withdrawn = scenario.rule_check(task, rule: rule, result: "withdrawn")
    scenario.rule_check(task, rule: other, result: "failed")
    times(passed, queued: 0, started: 10, finished: 40)
    times(failed, queued: 100, started: 105, finished: 125)
    times(running, queued: 200)
    times(skipped, queued: 300, started: 300, finished: 900)
    times(withdrawn, queued: 300, started: 310, finished: 1000)
    job_of(passed).update_columns(tokens: 100, spend: 0.25)
    job_of(failed).update_columns(tokens: 300, spend: 0.5)
    job_of(withdrawn).update_columns(tokens: 7, spend: 0.01)

    body = read

    assert_equal({ "checks" => 3, "average_seconds" => 32.5, "tokens" => 407, "spend" => 0.76, "overrides" => 1 },
      entry(body, rule)["stats"])
    assert_equal({ "checks" => 1, "overrides" => 0 }, entry(body, other)["stats"].slice("checks", "overrides"))
  end

  test "a rule no check has run for has zero counts and no average" do
    rule = scenario.rule
    scenario.rule_check(working_task, rule: rule)

    assert_equal({ "checks" => 1, "average_seconds" => nil, "tokens" => 0, "spend" => 0.0, "overrides" => 0 },
      entry(read, rule)["stats"])
    assert_equal({ "rules" => [] }, read(workspace_id: Scenario.new.workspace_id))
  end

  test "another workspace's rules and checks are never read, and the read writes nothing" do
    elsewhere = Scenario.new
    foreign = elsewhere.rule
    elsewhere.rule_check(elsewhere.task(state: "working", builder: elsewhere.seat(role: "builder")), rule: foreign,
      result: "passed")
    mine = scenario.rule
    before = [ Event.count, Command.count, Rule.count, RuleVersion.count ]

    body = read

    assert_equal [ mine.id ], body["rules"].map { |item| item.dig("rule", "id") }
    assert_equal 0, entry(body, mine).dig("stats", "checks")
    assert_equal before, [ Event.count, Command.count, Rule.count, RuleVersion.count ]
  end

  test "an unknown workspace is not found" do
    assert_raises(ActiveRecord::RecordNotFound) { Leverage::Reads::Rules.call(SecureRandom.uuid) }
  end
end

# The questions of PRD L315 to L318 per rule (Reads::RuleTiming; milestone 4
# plan RD-26): its attempts' queue and run time, how long it held tasks up,
# its tokens and spend, and its rows counted by result, with its overrides.
class RuleTimingReadTest < CommittingTestCase
  # rule_checks.overridden_by_user_id references users, and a committing
  # test leaves its rows behind: the tests that delete every user (those of
  # create_owner and the owner's session) would meet this test's overrides.
  # Clear the references it made.
  teardown { RuleCheck.where(workspace_id: scenario.workspace_id).update_all(overridden_by_user_id: nil) }

  def t0 = @t0 ||= scenario.database_now.change(usec: 0) - 7200

  def timing(**options) = Leverage::Reads::RuleTiming.call(scenario.workspace_id, **options)

  def of(answer, rule) = answer.find { |row| row.fetch("rule_id") == rule.id }

  def attempts(check) = RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).to_a

  def at(seconds) = seconds && t0 + seconds

  def working_task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))

  # A step row on the task, as the step tracker writes one, at seconds
  # after t0.
  def step(task, kind:, opened:, closed:, step_class: "waiting", subject: nil, cause_rule: nil)
    TaskStep.create!(workspace_id: task.workspace_id, task_id: task.id, round: task.round, kind: kind, step_class: step_class,
      subject_kind: subject && Leverage::EventLog.kind_of(subject), subject_id: subject&.id,
      cause_kind: (cause_rule && "rule"), cause_rule_id: cause_rule&.id, opened_at: at(opened), closed_at: at(closed),
      opening_event_id: Event.where(task_id: task.id).order(:seq).pick(:id))
  end

  def hold_row(task, reason:, rule:, check: nil)
    Hold.create!(workspace_id: task.workspace_id, task_id: task.id, reason: reason, rule_id: rule.id,
      rule_check_id: check&.id, opened_at: t0, opened_by_kind: "app")
  end

  test "queue time is started minus queued and run time finished minus started; an attempt that never started waited until its job ended, and an open one is measured to as_of" do
    rule = scenario.rule
    app = scenario.rule(checker: "app", checker_function: "minimum_criteria_count", parameters: { "minimum_count" => 1 },
      hook: "task.before_ready")
    task = working_task
    twice = scenario.rule_check(task, rule: rule, result: "passed", attempts: 2)
    first, second = attempts(twice)
    first.update_columns(queued_at: at(0), started_at: nil, finished_at: nil)
    Job.find(first.job_id).update_columns(finished_at: at(120))
    second.update_columns(queued_at: at(120), started_at: at(150), finished_at: at(200))
    waiting = scenario.rule_check(task, rule: rule)
    attempts(waiting).sole.update_columns(queued_at: at(1000))
    scenario.rule_check(task, rule: app, result: "passed")

    answer = timing(as_of: at(1100))

    row = of(answer, rule)
    assert_equal 3, row["attempts"]
    assert_equal 120 + 30 + 100, row["queue_seconds"]
    assert_equal 50, row["run_seconds"]
    assert_in_delta 250 / 3.0, row["average_queue_seconds"], 1e-6
    assert_equal 50, row["average_run_seconds"], "the open attempt has not started, so it has no run time"
    assert_equal 1, of(answer, app)["attempts"]
    assert_equal [ 0, 0 ], of(answer, app).values_at("queue_seconds", "run_seconds")
  end

  test "a rule held tasks up: each blocking check finished minus queued less its wait_owner time, a check step credited to the check that finished last, plus the wait_owner steps its failed or errored checks' holds opened and the wait_review steps naming it" do
    rule = scenario.rule
    beside = scenario.rule
    noted = scenario.rule(on_fail: "warn")
    task = working_task
    pending = scenario.pending_transition(task, command: "submit", requester: Seat.find(task.holder_seat_id))
    earlier = scenario.rule_check(task, rule: beside, result: "passed", pending: pending)
    attempts(earlier).sole.update_columns(queued_at: at(0), started_at: at(5), finished_at: at(60))
    last = scenario.rule_check(task, rule: rule, result: "error", pending: pending)
    attempts(last).sole.update_columns(queued_at: at(0), started_at: at(10), finished_at: at(100))
    warned = scenario.rule_check(task, rule: noted, result: "failed", pending: pending)
    attempts(warned).sole.update_columns(queued_at: at(0), started_at: at(1), finished_at: at(500))
    owner_hold = hold_row(task, reason: "owner_hold", rule: beside)
    step(task, kind: "wait_owner", opened: 20, closed: 50, subject: owner_hold)
    errored = hold_row(task, reason: "check_error", rule: rule, check: last)
    step(task, kind: "wait_owner", opened: 100, closed: 130, subject: errored)
    other = scenario.task(state: "in_review")
    step(other, kind: "wait_review", opened: 0, closed: 40, cause_rule: rule)

    answer = timing(as_of: at(2000))

    assert_equal 70 + 30 + 40, of(answer, rule)["held_up_seconds"]
    assert_equal 0, of(answer, beside)["held_up_seconds"], "the check step is the check that finished last's"
    assert_equal 0, of(answer, noted)["held_up_seconds"], "a warn check blocks nothing"
  end

  test "tokens and spend are its jobs' results, its rows are counted by result, and its overrides" do
    rule = scenario.rule
    task = working_task
    passed = scenario.rule_check(task, rule: rule, result: "passed")
    failed = scenario.rule_check(task, rule: rule, result: "failed")
    failed.update_columns(overridden_at: scenario.database_now, overridden_by_user_id: scenario.owner.id)
    scenario.rule_check(task, rule: rule, result: "failed")
    scenario.rule_check(task, rule: rule)
    Job.find(attempts(passed).sole.job_id).update_columns(tokens: 1200, spend: 0.03)
    Job.find(attempts(failed).sole.job_id).update_columns(tokens: 800, spend: 0.02)

    row = of(timing, rule)

    assert_equal 2000, row["tokens"]
    assert_in_delta 0.05, row["spend"], 1e-9
    assert_equal({ "passed" => 1, "failed" => 2, "unfinished" => 1 }, row["results"])
    assert_equal 1, row["overrides"]
  end

  test "rule_id: answers one rule, a removed one too, and a rule with no check answers zeros" do
    rule = scenario.rule
    gone = scenario.rule
    gone.update_columns(removed_at: scenario.database_now)

    assert_equal [ gone.id ], timing(rule_id: gone.id).map { |row| row["rule_id"] }
    row = timing(rule_id: rule.id).sole
    assert_equal({ "rule_id" => rule.id, "key" => rule.key, "removed" => false, "attempts" => 0, "queue_seconds" => 0,
                   "run_seconds" => 0, "average_queue_seconds" => nil, "average_run_seconds" => nil, "held_up_seconds" => 0,
                   "tokens" => 0, "spend" => 0.0, "results" => {}, "overrides" => 0 }, row)
    assert_equal true, timing.find { |candidate| candidate["rule_id"] == gone.id }["removed"]
  end
end

# leverage:rule_timing (milestone 4 plan §2.1, §5.2 step 2): prints the
# answer of Reads::RuleTiming for each rule, by key and id, with no rule
# text: a custom rule's name and instruction are the owner's content.
class RuleTimingTaskTest < CommittingTestCase
  def run_task(workspace_id)
    Rails.application.load_tasks unless Rake::Task.task_defined?("leverage:rule_timing")
    task = Rake::Task["leverage:rule_timing"]
    task.reenable
    saved = ENV["WORKSPACE_ID"]
    ENV["WORKSPACE_ID"] = workspace_id
    capture_io { task.invoke }.first
  ensure
    ENV["WORKSPACE_ID"] = saved
  end

  test "it prints each rule of the workspace by key and id with its figures, and none of its text" do
    marker = "MADEUP#{SecureRandom.hex(4).upcase}"
    rule = scenario.rule(name: "Name #{marker}", instruction: "Instruction #{marker}.")
    task = scenario.task(state: "working", builder: scenario.seat(role: "builder"))
    check = scenario.rule_check(task, rule: rule, result: "failed", reason: "Reason #{marker}.")
    Job.find(RuleCheckAttempt.where(rule_check_id: check.id).sole.job_id).update_columns(tokens: 4321)

    out = run_task(scenario.workspace_id)

    assert_includes out, scenario.workspace_id
    line = out.lines.find { |candidate| candidate.include?(rule.id) }
    assert line, out
    assert_includes line, rule.key
    assert_includes line, "4321 tokens"
    assert_includes line, "failed 1"
    assert_not_includes out, marker
  end

  test "an unknown workspace is refused" do
    error = assert_raises(SystemExit) { run_task(SecureRandom.uuid) }
    assert_not error.success?
  end
end
