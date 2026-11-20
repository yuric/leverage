require "test_helper"
require_relative "../support/trace_runner"

# Golden traces (PRD test 8; milestone 2 plan TS-8): every trace whose
# commands all have an entry in Transitions::Table and whose setup has no
# rule runs whole through the engine, and its events and steps are compared
# with the trace's field for field and row for row (TraceRunner). Each
# trace that cannot run whole is named in NOT_YET with the milestone that
# lets it and a prefix: the number of its leading commands that run before
# the first one a rule, a later command or a later event would change. A
# trace in neither set, or in both, fails.
class GoldenTracesTest < ActiveSupport::TestCase
  # trace => [milestone, prefix]. Every one of them starts with a command
  # milestone 2 cannot run as written: 04 with add_rule (milestone 4), the
  # others with add_task naming a project ($project:site), which add_task
  # refuses because tasks have no project until milestone 5 (SC-8, Q-3;
  # WP3's choice 1). So every prefix is 0, and the milestone is 5, when
  # projects arrive and rules (milestone 4) are already there; 03 and 04
  # also reach Finishing with outward actions (milestone 5, the TS8-check).
  #
  # The handoff milestone's traces 11 to 15 wait for its own entries
  # (milestone 3 plan HT-6): each prefix is the commands milestone 2 runs
  # as written before the first command of milestone 3. Trace 15's is 0,
  # because milestone 2 refuses Add task into the Imaginarium (SC-4).
  NOT_YET = {
    "01-happy-path" => [ 5, 0 ],
    "02-failed-review-rework" => [ 5, 0 ],
    "03-stop-rework-pass-approve-done" => [ 5, 0 ],
    "04-two-actions-custom-rule" => [ 5, 0 ],
    "05-limit-handoff" => [ 5, 0 ],
    "06-signed-out-hold-verify" => [ 5, 0 ],
    "07-pending-gate-check-error-override" => [ 5, 0 ],
    "08-lease-expiry-and-cancel" => [ 5, 0 ],
    "11-limit-handoff-no-rules" => [ 3, 7 ],
    "12-signed-out-hold-verify-no-rules" => [ 3, 7 ],
    "13-limit-next-signed-out-no-rules" => [ 3, 7 ]
  }.freeze

  NAMES = Dir[Rails.root.join("contract/traces/*.json")].map { |path| File.basename(path, ".json") }.sort.freeze

  def self.trace(name) = Leverage::Contract.trace(name)

  # Whole: every command has an entry and the setup has no rule.
  def self.runnable?(name)
    trace = trace(name)
    Array(trace.fetch("setup")["rules"]).empty? &&
      trace.fetch("commands").all? { |command| Leverage::Transitions::Table.include?(command.fetch("command")) }
  end

  RUN = NAMES.select { |name| runnable?(name) }.freeze

  test "every trace is run whole or named in NOT_YET, and none is both" do
    assert_equal NAMES, (RUN + NOT_YET.keys).sort, "a trace is in neither list"
    assert_empty RUN & NOT_YET.keys, "a trace that runs whole is still in NOT_YET"
    assert_includes RUN, "09-core-loop-no-rules"
    assert_includes RUN, "10-leases-no-rules"
  end

  test "each NOT_YET trace names a later milestone and a prefix of commands milestone 2 has" do
    NOT_YET.each do |name, (milestone, prefix)|
      assert_operator milestone, :>, 2, name
      commands = self.class.trace(name).fetch("commands")
      assert_includes 0..commands.size, prefix, name
      commands.first(prefix).each do |command|
        assert Leverage::Transitions::Table.include?(command.fetch("command")), "#{name}: #{command.fetch("command")}"
      end
    end
  end

  # Written for the traces of milestone 1, which wait for a later milestone
  # than 3. The handoff milestone's traces (11 to 15) start with add_task
  # and no project, a command milestone 2 has, so the check does not apply
  # to them (milestone 3 plan HT-6).
  test "the first command of every NOT_YET trace of a later milestone than 3 is one milestone 2 cannot run as written" do
    NOT_YET.each do |name, (milestone, _prefix)|
      next if milestone <= 3

      first = self.class.trace(name).fetch("commands").first
      if Leverage::Transitions::Table.include?(first.fetch("command"))
        assert first.fetch("body")["project_id"], "#{name}: its first command could run, so its prefix is not 0"
      else
        assert_equal "add_rule", first.fetch("command"), name
      end
    end
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
