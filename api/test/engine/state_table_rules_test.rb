require "test_helper"
require_relative "entries/rule_support"

# Test 3 (PRD L836; milestone 4 plan RT-5) for the rule records and the
# owner's two check commands: every state_machine.json row of the groups
# rules, install_shipped_rules and rule_checks, run through the real entry.
# Each row reads no task state (from: null) and changes none (to: null).
# A case checks the row's refusal or completion, its events and side effects. Three of the rows'
# events are written by another package's seam, which does nothing until
# that package lands (RuleChecks is WP4's, Jobs WP6's): for those the case
# proves the call instead (STUBBED), as the plan's shared run rules ask.
# The side events a row writes only when something else holds (a hold to
# close, a check in flight) are proven in the entries' own tests.
class StateTableRulesTest < ActiveSupport::TestCase
  include RuleSupport

  GROUPS = %w[rules install_shipped_rules rule_checks].freeze

  # The events whose writer is a seam of another package, and that seam.
  # Run it again queues through RuleChecks.queue_attempt (check.queued,
  # then Jobs.queue: trace 19 command 20; WP4's request 1, settled by WP12).
  STUBBED = { "check.queued" => "RuleChecks.queue_attempt", "job.queued" => "Jobs.queue",
              "check.overridden" => "RuleChecks.override" }.freeze
  SEAMS = { Leverage::RuleChecks => %i[queue_attempt override], Leverage::Jobs => %i[queue] }.freeze

  def self.commands
    Leverage::Contract.state_machine.fetch("groups").select { |group| GROUPS.include?(group.fetch("id")) }
      .flat_map { |group| group.fetch("rows").map { |row| row.fetch("command") } }.uniq
  end

  setup { use_scenario }

  test "the three groups hold the ten commands of plan section 2.1" do
    assert_equal %w[add_rule save_rule enable_rule disable_rule revert_rule remove_rule install_shipped_rules rerun_check
                    override_check].sort, self.class.commands.sort
    self.class.commands.each { |command| assert Leverage::Transitions::Table.entry_for(command), command }
  end

  StateTableCases.define(self, commands) do |kase|
    assert_nil kase.from, "the rule rows read no task state"
    assert_nil kase.to, "the rule rows change no task state"
    assert_nil kase.hook
    expected = if kase.command == "install_shipped_rules"
      [ { "event" => "rule.reverted", "when" => "rule_on_superseded_default" } ]
    else
      []
    end
    assert_equal expected, kase.conditional_events

    command = prepare(kase)
    before = scenario.workspace.reload.last_seq
    outcome = nil
    calls = recording(SEAMS, fakes: { "Jobs.queue" => ->(*, task:, target:, **) { fake_job(task, target) } }) do
      outcome = command.call
    end
    written = Event.where(workspace_id: scenario.workspace_id).where("seq > ?", before).order(:seq).map(&:type)

    if kase.refusal
      assert_refused(kase.refusal, outcome)
    else
      assert_completed(outcome)
    end
    own = kase.events - STUBBED.keys
    times = kase.command == "install_shipped_rules" ? Leverage::Rules::Shipped.all.size : 1
    assert_equal own * times, written.select { |type| own.include?(type) }, "#{kase.name}: the row's events"
    allowed = kase.events + kase.row.fetch("side_events").map { |side| side.fetch("event") }
    assert_empty written - allowed, "#{kase.name} writes only its row's events and side events"
    (kase.events & STUBBED.keys).each do |event|
      assert_equal 1, calls.fetch(STUBBED.fetch(event)).size, "#{kase.name}: #{event} through #{STUBBED.fetch(event)}"
    end
    (STUBBED.keys - kase.events).each do |event|
      assert_empty calls.fetch(STUBBED.fetch(event)), "#{kase.name} does not write #{event}"
    end
  end

  private

  # Builds what the case's row starts from; returns what runs its command.
  def prepare(kase)
    assert_equal [ kase.command == "install_shipped_rules" ? "app" : "owner" ], kase.who
    case kase.command
    when "install_shipped_rules"
      at = scenario.database_now
      -> { Leverage::Timers.apply_workspace(scenario.workspace, "install_shipped_rules", at: at) }
    when "add_rule" then -> { owner_command("add_rule", add_body) }
    when "save_rule" then rule_command(kase, scenario.rule) { |rule| save_body(rule) }
    when "enable_rule" then rule_command(kase, scenario.rule(enabled: false))
    when "disable_rule", "remove_rule" then rule_command(kase, scenario.rule)
    when "revert_rule" then rule_command(kase, scenario.with_shipped_rules.first)
    when "rerun_check"
      check = errored_check(kase.guard)
      -> { owner_command("rerun_check", { "id" => check.id }) }
    when "override_check"
      check = failed_check
      -> { owner_command("override_check", { "id" => check.id, "reason" => "Made-up reason." }) }
    else flunk "no case for #{kase.command}"
    end
  end

  def rule_command(kase, rule)
    body = (block_given? ? yield(rule) : {}).merge("id" => rule.id)
    -> { owner_command(kase.command, body) }
  end

  def builder = @builder ||= scenario.seat(role: "builder", credential: scenario.credential)

  # rerun_queues: an errored check a submit waits on. rerun_of_claim_check:
  # an errored claim check whose check_error hold is open. An errored
  # approval-policy check belongs to a requested action in Finishing.
  def errored_check(guard)
    if guard == [ "rerun_of_approval_check" ]
      rule = scenario.rule(key: "orchestrator_approves_actions", origin: "shipped")
      task = scenario.finishing_task(builder: builder, actions: [ { kind: "send", state: "requested" } ])
      action = Action.find_by!(task_id: task.id)
      return scenario.rule_check(task, rule: rule, result: "error", attempts: 2, subject: action)
    end

    if guard == [ "rerun_of_claim_check" ]
      rule = scenario.rule(hook: "task.before_claim")
      task = scenario.task(state: "ready")
      check = scenario.rule_check(task, rule: rule, result: "error", attempts: 2, subject: builder)
    else
      assert_equal [ "rerun_queues" ], guard
      rule = scenario.rule(hook: "task.before_submit")
      task = scenario.task(state: "working", builder: builder)
      pending = scenario.pending_transition(task, command: "submit", requester: builder)
      check = scenario.rule_check(task, rule: rule, result: "error", attempts: 2, pending: pending)
    end
    rule_hold(task, "check_error", rule: rule, check: check)
    check
  end

  def failed_check
    rule = scenario.rule(hook: "task.before_submit")
    scenario.rule_check(scenario.task(state: "working", builder: builder), rule: rule, result: "failed")
  end
end
