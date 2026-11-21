require "test_helper"
require_relative "../support/trace_runner"

# Golden traces (PRD test 8, AT-6): run every trace through the engine with
# its setup's rules, and compare its events and steps field for field.
class GoldenTracesTest < ActiveSupport::TestCase
  NAMES = Dir[Rails.root.join("contract/traces/*.json")].map { |path| File.basename(path, ".json") }.sort.freeze

  NAMES.each do |name|
    test "trace #{name} runs whole and writes exactly its events and steps" do
      runner = TraceRunner.new(name).run
      assert_empty runner.failures, runner.failures.join("\n")
      assert_empty Leverage::Replay.diff(runner.workspace_id), "the replay of #{name}'s log"
      assert_empty Leverage::LogAudit.call(runner.workspace_id, after_seq: runner.setup_seq), "the log audit of #{name}"
    end
  end

  test "the builder is told to resume after the owner answers a blocking question" do
    runner = TraceRunner.new("20-questions-and-access").run(17)
    assert_empty runner.failures, runner.failures.join("\n")

    task = Task.find_by!(workspace_id: runner.workspace_id)
    builder = Seat.find(task.holder_seat_id)
    assert_equal({ "kind" => "resume", "id" => task.id, "review_id" => nil }, Leverage::Reads::NextItem.call(builder))
  end

  # The runner checks the traces' lease arithmetic (L116-L120), not only the
  # order of their times: a timer's due time is one lease length after the
  # grant, in the trace and in the engine's own row, before make_due moves
  # it (EN-18).
  def changed_trace(name)
    JSON.parse(JSON.generate(Leverage::Contract.trace(name)))
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
