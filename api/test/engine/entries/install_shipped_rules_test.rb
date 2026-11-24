require "test_helper"
require_relative "rule_support"
require_relative "../../support/trace_runner"

# Entries::InstallShippedRules (PRD L434 with Q-12; milestone 4 plan RD-1
# to RD-3, S-1): the app writes the seven shipped rules of a workspace that
# has none, as the app with no key, through Timers.apply_workspace (the
# path the sweep uses for a workspace timer). It also upgrades untouched
# superseded shipped defaults (UI-5).
class InstallShippedRulesTest < ActiveSupport::TestCase
  include RuleSupport

  setup { use_scenario }

  def install(at: scenario.database_now) = Leverage::Timers.apply_workspace(scenario.workspace, "install_shipped_rules", at: at)

  def events = Event.where(workspace_id: scenario.workspace_id).order(:seq)

  test "it writes rule.created for each shipped rule, as the app with no key, after the workspace's earlier events" do
    task = scenario.task(state: "backlog")
    before = scenario.workspace.reload.last_seq
    at = scenario.database_now

    outcome = install(at: at)

    assert_completed(outcome)
    written = events.where("seq > ?", before).to_a
    rules = Rule.where(workspace_id: scenario.workspace_id).to_a.index_by(&:id)
    assert_equal [ "rule.created" ] * 7, written.map(&:type)
    assert_equal Leverage::Rules::Shipped.all.map(&:key), written.map { |event| rules.fetch(event.subject_id).key }
    written.each do |event|
      assert_equal [ "app", nil, nil, nil ], [ event.actor_kind, event.actor_id, event.command_id, event.task_id ]
      assert_equal at, event.effective_at, "the time apply_workspace was given"
    end
    assert_equal [ [ "app", nil ] ], RuleVersion.where(workspace_id: scenario.workspace_id).distinct.pluck(:author_kind, :author_id)
    assert_equal "backlog", task.reload.state, "a task already made is not touched (L379, RD-3)"
    assert_nil Command.find_by(workspace_id: scenario.workspace_id, command: "install_shipped_rules"), "no key, no commands row"
  end

  test "a workspace with rules and no superseded default is refused invalid_state and gets nothing" do
    scenario.rule
    counts = [ Rule.count, Event.count ]

    outcome = install

    assert_refused("invalid_state", outcome)
    assert_equal counts, [ Rule.count, Event.count ]
  end

  test "a second run on the same workspace writes nothing" do
    install
    counts = [ Rule.count, RuleVersion.count, Event.count ]

    assert_refused("invalid_state", install)
    assert_equal counts, [ Rule.count, RuleVersion.count, Event.count ]
  end

  [ true, false ].each do |enabled|
    test "a superseded shipped default is reverted once with enabled=#{enabled}" do
      shipped = Leverage::Contract.shipped_rules.fetch("rules").find { |row| row.fetch("key") == "specific_details" }
      earlier = shipped.fetch("superseded_instructions").first
      rule = scenario.rule(key: "specific_details", origin: "shipped", instruction: earlier, enabled: enabled)
      old = scenario.current_version(rule)
      before = scenario.workspace.reload.last_seq

      assert_completed(install)

      version = scenario.current_version(rule)
      assert_equal [ 2, enabled, shipped.fetch("instruction"), "app", nil ],
        [ version.version, rule.enabled, version.instruction, version.author_kind, version.author_id ]
      assert_equal earlier, old.reload.instruction
      assert_equal 1, Rule.where(workspace_id: scenario.workspace_id).count
      written = events.where("seq > ?", before).to_a
      assert_equal 1, written.size
      event = written.first
      assert_equal [ "rule.reverted", rule.id, "app", nil, nil ],
        [ event.type, event.subject_id, event.actor_kind, event.actor_id, event.command_id ]
      assert_equal({ "rule_version_id" => version.id, "version" => 2 }, event.payload)
      assert_empty Leverage::LogAudit.call(scenario.workspace_id, after_seq: before)
      assert_empty Leverage::Replay.diff(scenario.workspace_id)

      assert_no_difference -> { events.count } do
        assert_refused("invalid_state", install)
      end
      assert_equal 2, rule.reload.current_version
    end
  end

  test "installation leaves owner edits to the instruction and other fields alone" do
    shipped = Leverage::Contract.shipped_rules.fetch("rules").find { |row| row.fetch("key") == "specific_details" }
    changed = scenario.rule(key: "specific_details", origin: "shipped", instruction: "Use the sample format.")
    other = Scenario.new
    earlier = shipped.fetch("superseded_instructions").first
    changed_timeout = other.rule(key: "specific_details", origin: "shipped", instruction: earlier, run_timeout_seconds: 91)

    assert_no_difference [ -> { Event.count }, -> { RuleVersion.count } ] do
      assert_refused("invalid_state", install)
      assert_refused("invalid_state", Leverage::Timers.apply_workspace(other.workspace, "install_shipped_rules", at: other.database_now))
    end
    assert_equal "Use the sample format.", scenario.current_version(changed).instruction
    assert_equal [ earlier, 91 ], other.current_version(changed_timeout).attributes.values_at("instruction", "run_timeout_seconds")
  end

  # Trace 19's setup has two Gemini logins (gemini_h, gemini_r), which
  # the schema refuses (index_credentials_one_gemini_login_per_workspace),
  # so its setup cannot be built as written (in WP8's notes, for the trace's
  # owner). Its first command needs no login: the copy run here leaves out
  # the second Gemini login and the seats on it.
  test "trace 19's first command: the seven rule.created on a workspace with none" do
    name = "19-provider-rule-offline-and-jobs"
    trace = Leverage::Contract.trace(name).deep_dup
    setup = trace.fetch("setup")
    setup["credentials"] = setup.fetch("credentials").reject { |row| row.fetch("id") == "$credential:gemini_r" }
    setup["seats"] = setup.fetch("seats").reject { |row| row["credential_id"] == "$credential:gemini_r" }
    runner = TraceRunner.new(name, trace: trace).run(1)

    assert_empty runner.failures
    assert_equal 7, Rule.where(workspace_id: runner.workspace_id).count
  end
end
