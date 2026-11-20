require_relative "accounts_support"
require_relative "call_spy"

# What the tests of the rule records and the owner's two check commands
# share (milestone 4 plan WP8): the owner's requests of AccountsSupport,
# the events one command wrote, the bodies of AddRuleRequest and
# SaveRuleRequest, holds a rule opened, and a recorder for the calls an
# entry makes to a seam another package finishes (RuleChecks and
# PendingTransitions are WP4's, Jobs WP6's). Those seams do nothing until
# their packages land, so a test proves the call and its arguments, as the
# plan's shared run rules ask; a fake may stand in for what one answers.
# Every value is made up.
module RuleSupport
  include AccountsSupport
  include CallSpy

  L = Leverage

  # The events the command with this key wrote, in seq order.
  def written_by(key) = Event.where(workspace_id: scenario.workspace_id, command_id: key).order(:seq).to_a

  # Runs an owner command with a new key; returns [outcome, events it wrote].
  def owner_run(command, params = {}, key: new_key)
    outcome = owner_command(command, params, key: key)
    [ outcome, written_by(key) ]
  end

  # An AddRuleRequest body (a custom rule at a moment).
  def add_body(hook: "task.before_submit", **overrides)
    { "name" => "Made-up rule: the note names the tests",
      "instruction" => "Made-up instruction: the handoff note names each test that ran.", "hook" => hook,
      "scope" => { "kind" => "all_tasks", "project_ids" => nil, "action_kinds" => nil } }.merge(overrides.transform_keys(&:to_s))
  end

  # A SaveRuleRequest body with every field as the rule's current version
  # has it (what the screen sends for the fields it does not edit, RD-6),
  # with overrides.
  def save_body(rule, **overrides)
    version = scenario.current_version(rule)
    { "name" => version.name, "instruction" => version.instruction,
      "parameters" => version.parameters,
      "scope" => { "kind" => version.scope_kind, "project_ids" => nil, "action_kinds" => nil },
      "on_fail" => version.on_fail, "route" => version.route,
      "queue_timeout_seconds" => version.queue_timeout_seconds,
      "run_timeout_seconds" => version.run_timeout_seconds }.merge(overrides.transform_keys(&:to_s))
  end

  # Opens a rule's hold on a task through Holds, as the app does, with its
  # Needs you item, and names the check it is about (holds.rule_check_id,
  # which the plan's PlannedHold carries; Holds.open does not take it yet).
  def rule_hold(task, reason, rule:, check: nil)
    ActiveRecord::Base.transaction(requires_new: true) do
      hold = L::Holds.open(scenario.context, task: task, reason: reason, rule_id: rule.id)
      hold.update_columns(rule_check_id: check.id) if check
      hold
    end
  end

  def open_holds(task) = L::Holds.open_holds(task.reload)

  # Records the calls of each listed module function inside the block.
  # targets is { Module => [name, ...] }; fakes is { "Module.name" =>
  # a callable } that answers instead of the real function (which, for a
  # seam not built yet, does nothing). Returns { "Module.name" => [Call] }.
  def recording(targets, fakes: {}, &block)
    pairs = targets.flat_map { |mod, names| Array(names).map { |name| [ mod, name ] } }
    calls = pairs.to_h { |mod, name| [ label(mod, name), [] ] }
    wrap(pairs, calls, fakes, &block)
    calls
  end

  # A minimal Job row, standing in for what Jobs.queue answers until WP6.
  def fake_job(task, check)
    Job.create!(workspace_id: scenario.workspace_id, kind: "rule_check", task_id: task.id, target_kind: "rule_check",
      target_id: check.id, seat_role: "orchestrator", state: "queued", queued_at: scenario.database_now, input: {})
  end

  private

  def label(mod, name) = "#{mod.name.demodulize}.#{name}"

  def wrap(pairs, calls, fakes, &block)
    return yield if pairs.empty?

    (mod, name), *rest = pairs
    original = mod.method(name)
    fake = fakes[label(mod, name)]
    seen = calls.fetch(label(mod, name))
    mod.define_singleton_method(name) do |*arguments, **keywords, &inner|
      seen << CallSpy::Call.new(arguments: arguments, keywords: keywords)
      fake ? fake.call(*arguments, **keywords) : original.call(*arguments, **keywords, &inner)
    end
    begin
      wrap(rest, calls, fakes, &block)
    ensure
      mod.define_singleton_method(name, original)
    end
  end
end
