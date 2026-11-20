require "test_helper"
require_relative "entries/rule_support"

# Leverage::RuleRecords (PRD L342, L379, L434; milestone 4 plan §2.1, RD-1
# to RD-7, RD-21 to RD-24, RD-45): the only writer of rules and
# rule_versions. It writes the shipped set, adds a custom rule, saves a
# version, switches a rule, reverts a shipped rule, removes a custom one,
# and withdraws what a rule turned off or removed had in flight. The
# withdrawal calls RuleChecks, Jobs and PendingTransitions, which other
# packages write, so those calls are proven by their arguments.
class RuleRecordsTest < ActiveSupport::TestCase
  include RuleSupport

  Records = Leverage::RuleRecords
  Shipped = Leverage::Rules::Shipped
  Trigger = Leverage::Gating::Trigger

  setup { use_scenario }

  # A Context as the owner's command with key has it, holding the lock.
  def owner_context(key: "key-records")
    request = T::Request.new(command: "save_rule", workspace_id: scenario.workspace_id, caller_kind: "owner",
      caller_id: scenario.owner.id, key: key, request_hash: "a" * 64, params: {})
    scenario.context(request: request)
  end

  def app_context
    request = T::Request.new(command: "install_shipped_rules", workspace_id: scenario.workspace_id, caller_kind: nil,
      caller_id: nil, key: nil, request_hash: nil, params: {})
    scenario.context(request: request)
  end

  def versions(rule) = RuleVersion.where(rule_id: rule.id).order(:version).to_a

  def rule_events(type = nil)
    scope = Event.where(workspace_id: scenario.workspace_id, subject_kind: "rule")
    (type ? scope.where(type: type) : scope).order(:seq).to_a
  end

  # --- the shipped set -------------------------------------------------------

  test "install_shipped writes the seven shipped rules at version 1, in shipped order, with rule.created each (L434)" do
    rules = Records.install_shipped(owner_context(key: "key-setup"))

    assert_equal Shipped.all.map(&:key), rules.map(&:key)
    assert_equal Shipped.all.map(&:key).sort, Rule.where(workspace_id: scenario.workspace_id).pluck(:key).sort
    rules.zip(Shipped.all).each do |rule, record|
      rule.reload
      assert_equal [ record.enabled, 1, nil ], [ rule.enabled, rule.current_version, rule.removed_at ], record.key
      version = versions(rule).sole
      assert_equal record.version_fields.transform_keys(&:to_s),
        version.attributes.slice(*record.version_fields.keys.map(&:to_s)), "#{record.key}: the shipped fields"
      assert_equal [ "owner", scenario.owner.id ], [ version.author_kind, version.author_id ]
    end
    events = rule_events
    assert_equal [ "rule.created" ] * 7, events.map(&:type)
    assert_equal rules.map(&:id), events.map(&:subject_id), "in shipped order"
    events.zip(rules).each do |event, rule|
      assert_equal({ "rule_version_id" => versions(rule).sole.id, "version" => 1, "enabled" => true }, event.payload)
      assert_equal [ "owner", scenario.owner.id, "key-setup", nil ], [ event.actor_kind, event.actor_id, event.command_id, event.task_id ]
    end
  end

  test "install_shipped run by the app writes them as the app, with no key and no author" do
    Records.install_shipped(app_context)

    assert_equal [ [ "app", nil, nil ] ] * 7, rule_events.map { |event| [ event.actor_kind, event.actor_id, event.command_id ] }
    assert_equal [ [ "app", nil ] ], RuleVersion.where(workspace_id: scenario.workspace_id).distinct.pluck(:author_kind, :author_id)
  end

  test "the placeholder instruction of the approvals rule is stored as no instruction, never as the placeholder" do
    Records.install_shipped(owner_context)
    version = RuleVersion.find_by!(workspace_id: scenario.workspace_id, key: "orchestrator_approves_actions")

    assert_nil version.instruction
    assert_kind_of String, RuleVersion.find_by!(workspace_id: scenario.workspace_id, key: "specific_details").instruction
  end

  # --- add -------------------------------------------------------------------

  test "add writes a custom model gate that blocks, keyed custom_ and its id, at version 1 (RD-4, RD-23, L464)" do
    rule = Records.add(owner_context(key: "key-add"), add_body(hook: "task.before_claim"))

    rule.reload
    assert_equal "custom_#{rule.id}", rule.key
    assert_equal [ true, 1 ], [ rule.enabled, rule.current_version ]
    version = versions(rule).sole
    assert_equal({ "key" => rule.key, "name" => add_body["name"], "hook" => "task.before_claim", "kind" => "gate",
                   "checker" => "model", "scope_kind" => "all_tasks", "scope_values" => [], "checker_function" => nil,
                   "parameters" => {}, "instruction" => add_body["instruction"], "checker_role" => "orchestrator",
                   "on_fail" => "block", "route" => "builder", "queue_timeout_seconds" => nil,
                   "run_timeout_seconds" => nil, "origin" => "custom", "author_kind" => "owner",
                   "author_id" => scenario.owner.id },
      version.attributes.except("id", "workspace_id", "rule_id", "version", "created_at"))
    event = rule_events("rule.created").sole
    assert_equal({ "rule_version_id" => version.id, "version" => 1, "enabled" => true }, event.payload)
    assert_equal [ rule.id, "key-add" ], [ event.subject_id, event.command_id ]
  end

  test "a custom rule's route is the owner at ready to start and the builder at the other three moments (RD-24, RC-7)" do
    routes = %w[task.before_ready task.before_claim task.before_submit task.before_done].to_h do |hook|
      [ hook, scenario.current_version(Records.add(owner_context, add_body(hook: hook))).route ]
    end

    assert_equal({ "task.before_ready" => "owner", "task.before_claim" => "builder", "task.before_submit" => "builder",
                   "task.before_done" => "builder" }, routes)
  end

  test "a custom rule may let the checker decide (RD-22, RC-47)" do
    scope = { "kind" => "checker_decides", "project_ids" => nil, "action_kinds" => nil }
    rule = Records.add(owner_context, add_body(scope: scope))

    assert_equal [ "checker_decides", [] ], scenario.current_version(rule).then { |version| [ version.scope_kind, version.scope_values ] }
  end

  test "add refuses what the milestone does not offer, as invalid, writing nothing (RD-21, RD-22)" do
    invalid = {
      "the moment before anything goes out (RD-21)" => add_body(hook: "action.requested"),
      "a hook that is not a gate's moment" => add_body(hook: "review.assign"),
      "named projects (RD-22)" => add_body(scope: { "kind" => "named_projects", "project_ids" => [ SecureRandom.uuid ], "action_kinds" => nil }),
      "action kinds (RD-22)" => add_body(scope: { "kind" => "action_kinds", "project_ids" => nil, "action_kinds" => [ "publish" ] }),
      "values with every task" => add_body(scope: { "kind" => "all_tasks", "project_ids" => [ SecureRandom.uuid ], "action_kinds" => nil }),
      "a blank name" => add_body(name: "  "),
      "a blank instruction" => add_body(instruction: ""),
      "no instruction" => add_body.except("instruction")
    }
    invalid.each do |what, body|
      assert_raises(T::Invalid, what) { Records.add(owner_context, body) }
    end
    assert_equal 0, Rule.where(workspace_id: scenario.workspace_id).count
    assert_empty rule_events
  end

  # --- save ------------------------------------------------------------------

  test "every save is a new version and the earlier row is left as it was (L342, L911)" do
    rule = scenario.rule(hook: "task.before_submit")
    first = scenario.current_version(rule)
    before = first.attributes

    version = Records.save(owner_context(key: "key-save"), rule, save_body(rule, instruction: "Made-up: a stricter wording."))
    again = Records.save(owner_context(key: "key-save-2"), rule, save_body(rule))

    assert_equal before, first.reload.attributes, "version 1 is untouched"
    assert_equal [ 2, 3 ], [ version.version, again.version ]
    assert_equal 3, rule.reload.current_version
    assert_equal "Made-up: a stricter wording.", version.instruction
    assert_equal "Made-up: a stricter wording.", again.instruction, "a save with nothing changed is still a version"
    assert_equal [ first.hook, first.kind, first.checker, first.checker_role, rule.key, "custom" ] * 2,
      [ version, again ].flat_map { |row| [ row.hook, row.kind, row.checker, row.checker_role, row.key, row.origin ] }
    events = rule_events("rule.changed")
    assert_equal [ { "rule_version_id" => version.id, "version" => 2 }, { "rule_version_id" => again.id, "version" => 3 } ],
      events.map(&:payload)
    assert_equal [ "key-save", "key-save-2" ], events.map(&:command_id)
  end

  test "save takes each field the request has: scope, warn, each of the three routes and the two timeouts (RD-6, RD-24)" do
    rule = scenario.rule(hook: "task.before_submit")

    %w[builder orchestrator owner].each do |route|
      version = Records.save(owner_context, rule, save_body(rule, route: route, on_fail: "warn",
        scope: { "kind" => "checker_decides", "project_ids" => nil, "action_kinds" => nil }, queue_timeout_seconds: 60,
        run_timeout_seconds: 400, name: "Made-up renamed rule"))
      assert_equal [ route, "warn", "checker_decides", 60, 400, "Made-up renamed rule" ],
        [ version.route, version.on_fail, version.scope_kind, version.queue_timeout_seconds, version.run_timeout_seconds, version.name ]
    end
  end

  test "save on a shipped app rule stores its parameters and keeps its function (L344)" do
    rule = scenario.with_shipped_rules.find { |row| row.key == "acceptance_criteria" }

    version = Records.save(owner_context, rule, save_body(rule, parameters: { "minimum_count" => 3 }))

    assert_equal [ { "minimum_count" => 3 }, "minimum_criteria_count", "app", nil ],
      [ version.parameters, version.checker_function, version.checker, version.instruction ]
  end

  test "save refuses fields that do not fit the rule, as invalid, writing nothing (RD-6)" do
    rules = scenario.with_shipped_rules.index_by(&:key)
    custom = scenario.rule(hook: "task.before_submit")
    criteria = rules.fetch("acceptance_criteria")
    details = rules.fetch("specific_details")
    provider = rules.fetch("different_provider_review")
    invalid = {
      "a shipped rule's name" => [ details, save_body(details, name: "Made-up other name") ],
      "a model rule with no instruction" => [ custom, save_body(custom, instruction: nil) ],
      "a model rule with a blank instruction" => [ details, save_body(details, instruction: " ") ],
      "an app rule with an instruction" => [ criteria, save_body(criteria, instruction: "Made-up words") ],
      "a parameter the function does not have" => [ criteria, save_body(criteria, parameters: { "minimum_count" => 1, "other" => 2 }) ],
      "a parameter missing" => [ criteria, save_body(criteria, parameters: {}) ],
      "a parameter of the wrong type" => [ criteria, save_body(criteria, parameters: { "minimum_count" => "3" }) ],
      "a parameter below its minimum" => [ criteria, save_body(criteria, parameters: { "minimum_count" => -1 }) ],
      "parameters on a model rule" => [ custom, save_body(custom, parameters: { "minimum_count" => 1 }) ],
      "let the checker decide on an app rule" => [ criteria, save_body(criteria, scope: { "kind" => "checker_decides", "project_ids" => nil, "action_kinds" => nil }) ],
      "named projects (RD-22)" => [ custom, save_body(custom, scope: { "kind" => "named_projects", "project_ids" => [ SecureRandom.uuid ], "action_kinds" => nil }) ],
      "action kinds (RD-22)" => [ custom, save_body(custom, scope: { "kind" => "action_kinds", "project_ids" => nil, "action_kinds" => [ "pay" ] }) ],
      "no on_fail on a gate (RC-10)" => [ custom, save_body(custom, on_fail: nil) ],
      "an on_fail on a policy" => [ provider, save_body(provider, on_fail: "block") ],
      "no route on a gate" => [ custom, save_body(custom, route: nil) ],
      "a route on a policy" => [ provider, save_body(provider, route: "owner") ],
      "a route no list has" => [ custom, save_body(custom, route: "reviewer") ],
      "a timeout of zero" => [ custom, save_body(custom, queue_timeout_seconds: 0) ],
      "a field missing" => [ custom, save_body(custom).except("run_timeout_seconds") ]
    }
    counts = [ RuleVersion.count, rule_events.size ]
    invalid.each do |what, (rule, body)|
      assert_raises(T::Invalid, what) { Records.save(owner_context, rule, body) }
    end
    assert_equal counts, [ RuleVersion.count, rule_events.size ]
  end

  test "the approvals rule, whose instruction is still to be written, may be saved with none (milestone 5 writes it)" do
    rule = scenario.with_shipped_rules.find { |row| row.key == "orchestrator_approves_actions" }

    version = Records.save(owner_context, rule, save_body(rule, scope: { "kind" => "checker_decides", "project_ids" => nil, "action_kinds" => nil }))

    assert_nil version.instruction
    assert_equal "checker_decides", version.scope_kind
  end

  # --- revert, switch, remove -----------------------------------------------

  test "revert writes the shipped fields as a new version (L342, RD-7)" do
    rule = scenario.with_shipped_rules.find { |row| row.key == "acceptance_criteria" }
    Records.save(owner_context, rule, save_body(rule, parameters: { "minimum_count" => 4 }, on_fail: "warn"))

    version = Records.revert(owner_context(key: "key-revert"), rule)

    assert_equal 3, version.version
    record = Shipped.find("acceptance_criteria")
    assert_equal record.version_fields.transform_keys(&:to_s), version.attributes.slice(*record.version_fields.keys.map(&:to_s))
    assert_equal [ "owner", scenario.owner.id ], [ version.author_kind, version.author_id ]
    event = rule_events("rule.reverted").sole
    assert_equal({ "rule_version_id" => version.id, "version" => 3 }, event.payload)
    assert_equal "key-revert", event.command_id
  end

  test "enable and disable switch the rule and write no version (DB-28)" do
    rule = scenario.rule(enabled: false)

    Records.enable(owner_context(key: "key-on"), rule)
    assert rule.reload.enabled
    Records.disable(owner_context(key: "key-off"), rule)
    refute rule.reload.enabled

    assert_equal 1, versions(rule).size
    assert_equal [ [ "rule.enabled", {}, "key-on" ], [ "rule.disabled", {}, "key-off" ] ],
      rule_events.drop(1).map { |event| [ event.type, event.payload, event.command_id ] }
  end

  test "remove marks the custom rule removed with rule.removed (DB-29)" do
    rule = scenario.rule

    Records.remove(owner_context(key: "key-remove"), rule)

    refute_nil rule.reload.removed_at
    assert_equal [ "rule.removed", "key-remove" ], rule_events.last.then { |event| [ event.type, event.command_id ] }
  end

  # --- what a rule turned off or removed withdraws (L379, RD-45) --------------

  # A Working task with a submit waiting on a check of rule, its job
  # claimed by the orchestrator; and another rule's check on another task.
  def in_flight_world
    builder = scenario.seat(role: "builder", credential: scenario.credential)
    @rule = scenario.rule(hook: "task.before_submit")
    other_rule = scenario.rule(hook: "task.before_submit")
    @task = scenario.task(state: "working", builder: builder)
    @pending = scenario.pending_transition(@task, command: "submit", requester: builder)
    @running = scenario.rule_check(@task, rule: @rule, pending: @pending, started: true)
    other_task = scenario.task(state: "working", builder: scenario.seat(role: "builder", credential: scenario.credential))
    @untouched = scenario.rule_check(other_task, rule: other_rule)
  end

  def job_of(check) = Job.find(RuleCheckAttempt.where(rule_check_id: check.id).order(:attempt_number).last.job_id)

  test "turning a rule off withdraws each of its checks in flight and its job, and gates the waiting command again (L379)" do
    in_flight_world

    calls = recording({ Leverage::RuleChecks => :withdraw, Leverage::Jobs => :withdraw,
                        Leverage::PendingTransitions => :reenter }) do
      Records.disable(owner_context, @rule)
    end

    assert_equal [ [ @running.id ] ], calls.fetch("RuleChecks.withdraw").map { |call| call.arguments.drop(1).map(&:id) }
    assert_equal [ [ job_of(@running).id ] ], calls.fetch("Jobs.withdraw").map { |call| call.arguments.drop(1).map(&:id) }
    reentry = calls.fetch("PendingTransitions.reenter").sole
    assert_equal @pending.id, reentry.arguments[1].id
    assert_equal Trigger.new(kind: :rule_switched_off, rule_check_id: @running.id), reentry.arguments[2]
  end

  test "a finished job is not withdrawn, and an errored check whose hold is open is withdrawn with it closed (L162, L400)" do
    in_flight_world
    errored = scenario.rule_check(@task, rule: @rule, result: "error", input_hash: "b" * 64, attempts: 2, pending: @pending)
    hold = rule_hold(@task, "check_error", rule: @rule, check: errored)
    done = scenario.rule_check(@task, rule: @rule, result: "failed", input_hash: "c" * 64)

    calls = recording({ Leverage::RuleChecks => :withdraw, Leverage::Jobs => :withdraw,
                        Leverage::PendingTransitions => :reenter }) do
      Records.disable(owner_context(key: "key-off"), @rule)
    end

    withdrawn = calls.fetch("RuleChecks.withdraw").map { |call| call.arguments[1].id }
    assert_equal [ @running.id, errored.id ].sort, withdrawn.sort
    refute_includes withdrawn, done.id, "a finished check keeps its result"
    assert_equal [ job_of(@running).id ], calls.fetch("Jobs.withdraw").map { |call| call.arguments[1].id },
      "the errored check's jobs timed out already"
    refute_nil hold.reload.closed_at
    closed = written_by("key-off").select { |event| event.type.start_with?("hold.", "inbox.") }
    assert_equal [ [ "hold.closed", "check_error" ], [ "inbox.resolved", nil ] ], closed.map { |event| [ event.type, event.payload["reason"] ] }
    assert_equal "turn_rule_off", closed.last.payload.fetch("choice")
    assert_equal [ [ "owner", nil ] ] * 2, closed.map { |event| [ event.actor_kind, event.cause_id ] }
    assert_equal 1, calls.fetch("PendingTransitions.reenter").size, "one re-entry for the one waiting command"
  end

  test "turning a rule off closes its claim_gate_failed and rerun_limit holds, and no other rule's (L162, L166, L167, RD-45)" do
    in_flight_world
    rule_hold(@task, "rerun_limit", rule: @rule, check: @running)
    ready = scenario.task(state: "ready")
    refused = rule_hold(ready, "claim_gate_failed", rule: @rule)
    other_rule = scenario.rule(hook: "task.before_claim")
    kept = rule_hold(scenario.task(state: "ready"), "claim_gate_failed", rule: other_rule)

    Records.disable(owner_context(key: "key-off"), @rule)

    assert_empty open_holds(@task)
    assert_empty open_holds(ready)
    assert_nil kept.reload.closed_at
    assert_equal %w[rerun_limit claim_gate_failed].sort,
      written_by("key-off").select { |event| event.type == "hold.closed" }.map { |event| event.payload.fetch("reason") }.sort
    assert refused.reload.closed_at
  end

  test "the waiting command is not gated again while another hold is open on its task (rule 9, L378)" do
    in_flight_world
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(scenario.context, task: @task, reason: "owner_hold", actor_kind: "owner", actor_id: scenario.owner.id)
    end

    calls = recording({ Leverage::PendingTransitions => :reenter }) { Records.disable(owner_context, @rule) }

    assert_empty calls.fetch("PendingTransitions.reenter")
  end

  test "a check of a command that is no longer waiting is withdrawn but nothing is gated again" do
    in_flight_world
    @pending.update!(state: "cancelled", params: nil)

    calls = recording({ Leverage::RuleChecks => :withdraw, Leverage::PendingTransitions => :reenter }) do
      Records.disable(owner_context, @rule)
    end

    assert_equal [ @running.id ], calls.fetch("RuleChecks.withdraw").map { |call| call.arguments[1].id }
    assert_empty calls.fetch("PendingTransitions.reenter")
  end

  test "removing a rule withdraws what it has in flight as turning it off does (L379)" do
    in_flight_world

    calls = recording({ Leverage::RuleChecks => :withdraw, Leverage::Jobs => :withdraw,
                        Leverage::PendingTransitions => :reenter }) do
      Records.remove(owner_context, @rule)
    end

    assert_equal [ @running.id ], calls.fetch("RuleChecks.withdraw").map { |call| call.arguments[1].id }
    assert_equal [ job_of(@running).id ], calls.fetch("Jobs.withdraw").map { |call| call.arguments[1].id }
    assert_equal [ @pending.id ], calls.fetch("PendingTransitions.reenter").map { |call| call.arguments[1].id }
  end

  test "turning a rule on or saving it touches no check in flight (L379: a request already made)" do
    in_flight_world
    @rule.update!(enabled: false)

    calls = recording({ Leverage::RuleChecks => :withdraw, Leverage::Jobs => :withdraw,
                        Leverage::PendingTransitions => :reenter }) do
      Records.enable(owner_context, @rule)
      Records.save(owner_context, @rule, save_body(@rule))
    end

    assert(calls.values.all?(&:empty?), calls.inspect)
    assert_equal @running.rule_version_id, @running.reload.rule_version_id, "the check keeps its frozen version (L911)"
  end
end
