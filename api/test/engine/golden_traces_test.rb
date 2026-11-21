require "test_helper"
require_relative "../support/trace_runner"

# Golden traces (PRD test 8; milestone 2 plan TS-8): every trace whose
# commands all have an entry in Transitions::Table runs whole through the
# engine, with its setup's rules (milestone 4 plan RT-1, RT-6: the rules
# engine is the production gating), and its events and steps are compared
# with the trace's field for field and row for row (TraceRunner). Each
# trace that cannot run whole is named in NOT_YET with the milestone that
# lets it and a prefix: the number of its leading commands that run before
# the first one a later command or a later event would change. A trace in
# neither set, or in both, fails.
class GoldenTracesTest < ActiveSupport::TestCase
  # trace => [milestone, prefix]. Traces 03 and 04 have outward actions
  # (their contracts name them, 04 adds a rule at action.requested, and
  # both reach Finishing: milestone 5, the TS8-check). Every other trace
  # runs whole from milestone 4 (its plan RT-6): 01, 02 and 05 to 08 name
  # a project, which add_task takes since RD-52, and their workspaces have
  # the shipped rules; 16 to 19 are milestone 4's own.
  NOT_YET = {
    "03-stop-rework-pass-approve-done" => [ 5, 1 ],
    "04-two-actions-custom-rule" => [ 5, 0 ],
    "20-questions-and-access" => [ 5, 0 ]
  }.freeze

  # The handoff milestone's five, which run whole (HT-1).
  HANDOFF = %w[11-limit-handoff-no-rules 12-signed-out-hold-verify-no-rules 13-limit-next-signed-out-no-rules
               14-handoff-edges-no-rules 15-owner-controls-no-rules].freeze

  # The milestone 1 traces milestone 4 runs whole, and its own four.
  RULE_CHECKS = %w[01-happy-path 02-failed-review-rework 05-limit-handoff 06-signed-out-hold-verify
                   07-pending-gate-check-error-override 08-lease-expiry-and-cancel 16-model-gate-and-draft
                   17-submit-rule-rerun-and-override 18-claim-gate-done-gate-and-ends
                   19-provider-rule-offline-and-jobs].freeze

  NAMES = Dir[Rails.root.join("contract/traces/*.json")].map { |path| File.basename(path, ".json") }.sort.freeze

  def self.trace(name) = Leverage::Contract.trace(name)

  # Whether the command has an entry, served or not yet in its group
  # (Table.entry_for, milestone 4 plan RT-6).
  def self.entry?(command)
    Leverage::Transitions::Table.entry_for(command)
    true
  rescue Leverage::Transitions::Table::UnknownCommand
    false
  end

  # Whole: every command has an entry.
  def self.runnable?(name)
    trace(name).fetch("commands").all? { |command| entry?(command.fetch("command")) }
  end

  RUN = NAMES.select { |name| runnable?(name) }.freeze

  test "every trace is run whole or named in NOT_YET, and none is both" do
    assert_equal NAMES, (RUN + NOT_YET.keys).sort, "a trace is in neither list"
    assert_empty RUN & NOT_YET.keys, "a trace that runs whole is still in NOT_YET"
    assert_includes RUN, "09-core-loop-no-rules"
    assert_includes RUN, "10-leases-no-rules"
    (HANDOFF + RULE_CHECKS).each { |name| assert_includes RUN, name }
  end

  test "each NOT_YET trace names a later milestone and a prefix of commands that have entries" do
    NOT_YET.each do |name, (milestone, prefix)|
      assert_operator milestone, :>, 4, name
      commands = self.class.trace(name).fetch("commands")
      assert_includes 0..commands.size, prefix, name
      commands.first(prefix).each do |command|
        assert self.class.entry?(command.fetch("command")), "#{name}: #{command.fetch("command")}"
      end
    end
  end

  # Each prefix is the longest one: the command after it is milestone 5's
  # (it has no entry, names an outward action, which add_task and Complete
  # contract refuse until then, SC-3, or a rule at action.requested, which
  # add_rule refuses, RD-21, or writes an outward action's event), and no
  # command before it is.
  test "the command after each NOT_YET trace's prefix is the first one that needs milestone 5" do
    NOT_YET.each do |name, (_milestone, prefix)|
      later = self.class.trace(name).fetch("commands").index { |command| self.class.later_milestone?(command) }
      assert_equal later, prefix, name
    end
  end

  def self.later_milestone?(command)
    body = command.fetch("body")
    !entry?(command.fetch("command")) || Array(body["actions"]).any? || body["hook"] == "action.requested" ||
      command.dig("expect", "events").any? { |event| event.fetch("type").start_with?("action.") }
  end

  RUN.each do |name|
    test "trace #{name} runs whole and writes exactly its events and steps" do
      runner = TraceRunner.new(name).run
      assert_empty runner.failures, runner.failures.join("\n")
      assert_empty Leverage::Replay.diff(runner.workspace_id), "the replay of #{name}'s log"
      assert_empty Leverage::LogAudit.call(runner.workspace_id, after_seq: runner.setup_seq), "the log audit of #{name}"
    end
  end

  NOT_YET.each do |name, (_milestone, prefix)|
    next if prefix.zero?

    test "trace #{name} runs its first #{prefix} commands" do
      runner = TraceRunner.new(name).run(prefix)
      assert_empty runner.failures, runner.failures.join("\n")
    end
  end

  # The runner checks the traces' lease arithmetic (L116-L120), not only the
  # order of their times: a timer's due time is one lease length after the
  # grant, in the trace and in the engine's own row, before make_due moves
  # it (EN-18).
  def changed_trace(name)
    JSON.parse(JSON.generate(self.class.trace(name)))
  end

  test "a trace whose lease ends at another time than one lease length after its grant fails" do
    trace = changed_trace("10-leases-no-rules")
    expiry = trace.fetch("commands").find { |command| command.fetch("command") == "builder_lease_expiry" }
    expiry.dig("expect", "events").first["effective_at"] = "@t:640"
    runner = TraceRunner.new("10-leases-no-rules", trace: trace).run

    assert(runner.failures.any? { |failure| failure.include?("lease") }, runner.failures.join("\n"))
  end

  # A reset time the trace sends is the one the timer's events carry: a
  # release dated at another time than the reset fails (milestone 3 plan
  # HE-23, trace 11: due at 2400, swept at 2430).
  test "a credential hold released at another time than its reset fails the trace" do
    trace = changed_trace("11-limit-handoff-no-rules")
    release = trace.fetch("commands").find { |command| command.fetch("command") == "credential_hold_release" }
    release.dig("expect", "events").each { |event| event["effective_at"] = "@t:2410" }
    runner = TraceRunner.new("11-limit-handoff-no-rules", trace: trace).run

    assert(runner.failures.any? { |failure| failure.include?("credential_hold_release") }, runner.failures.join("\n"))
  end

  # A credential_limit hold leaves the lease clock running (L116), so the
  # runner still checks its arithmetic: trace 14's lease ends one lease
  # length after the claim, through two limit holds.
  test "a lease that runs through a credential_limit hold is still checked" do
    trace = changed_trace("14-handoff-edges-no-rules")
    expiry = trace.fetch("commands").find { |command| command.fetch("command") == "builder_lease_expiry" }
    expiry.dig("expect", "events").each { |event| event["effective_at"] = "@t:3610" }
    runner = TraceRunner.new("14-handoff-edges-no-rules", trace: trace).run

    assert(runner.failures.any? { |failure| failure.include?("lease runs 3590 s") }, runner.failures.join("\n"))
  end

  test "an engine whose lease is not one lease length long fails the trace" do
    grant = Leverage::Leases.method(:grant)
    Leverage::Leases.define_singleton_method(:grant) do |ctx, subject, paused: false|
      grant.call(ctx, subject, paused: paused)
      subject.update!(lease_due_at: subject.lease_due_at + 1) if subject.lease_due_at
    end
    runner = TraceRunner.new("10-leases-no-rules").run

    assert(runner.failures.any? { |failure| failure.include?("lease") }, runner.failures.join("\n"))
  ensure
    Leverage::Leases.define_singleton_method(:grant, grant) if grant
  end
end
