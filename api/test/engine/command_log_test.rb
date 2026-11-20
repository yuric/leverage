require "test_helper"
require_relative "gate_support"

# CommandLog's one line per command (PRD L829, L832; milestone 4 plan RT-8,
# §0.1 fact 19): milestone 2's fields first, in their order, then a fourth
# timing, the time inside the gate, and the rule a blocked_by_rule refusal
# names. A refused command's line has its code and the rule's id, never
# the reason, a rule's instruction or any task text.
class CommandLogTest < ActiveSupport::TestCase
  include GateSupport

  LINE = /\Aleverage\.command command=(?<command>\S+) caller=(?<caller>\S+) key=(?<key>\S+) outcome=(?<outcome>\S+) refusal=(?<refusal>\S+) lock_wait_ms=(?<lock>\d+\.\d{3}) event_step_ms=(?<writes>\d+\.\d{3}) transition_ms=(?<total>\d+\.\d{3}) gate_ms=(?<gate>\d+\.\d{3}) rule=(?<rule>\S+)\z/

  REASON = "The handoff note names no test: made-up marker reason".freeze
  INSTRUCTION = "Made-up marker instruction: name each test.".freeze

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    @lines = []
    lines = @lines
    @logger = Rails.logger
    capture = Object.new
    capture.define_singleton_method(:info) { |line| lines << line }
    Rails.logger = capture
  end

  teardown { Rails.logger = @logger }

  def line_of(key) = @lines.map { |line| LINE.match(line) }.compact.find { |match| match[:key] == key }

  test "a command refused blocked_by_rule logs the code and the rule's id, and not the reason, the instruction or task text" do
    rule = app_rule("task.before_submit", instruction: INSTRUCTION)
    gating([ rule, { app_result: "failed", reason: REASON } ])
    task = ready_to_submit(@builder)
    params = submit_params(task, note: "Made-up marker handoff note.")
    outcome = command("submit", @builder, params)
    assert_equal REASON, outcome.refusal.reason

    line = line_of(@key)
    assert line, "the line has milestone 2's fields in their order, then gate_ms and rule: #{@lines.last}"
    assert_equal [ "submit", "seat:#{@builder.id}", "refused", "blocked_by_rule", rule.id ],
      line.values_at(:command, :caller, :outcome, :refusal, :rule)
    text = line.to_s
    [ REASON, "marker", INSTRUCTION, "handoff", task.title, task.goal ].each { |content| assert_not_includes text, content }
  end

  test "a completed command and another refusal name no rule; every line has four timings" do
    task = @scenario.task(state: "backlog")
    command("complete_contract", @owner, contract_params(task))
    completed = line_of(@key)
    command("complete_contract", @owner, contract_params(task))
    refused = line_of(@key)

    assert_equal [ "completed", "-", "-" ], completed.values_at(:outcome, :refusal, :rule)
    assert_equal [ "refused", "invalid_state", "-" ], refused.values_at(:outcome, :refusal, :rule)
  end

  test "the time inside the gate is part of the transition's" do
    task = @scenario.task(state: "backlog")
    command("complete_contract", @owner, contract_params(task))
    line = line_of(@key)

    assert_operator line[:gate].to_f, :>, 0
    assert_operator line[:gate].to_f, :<=, line[:total].to_f
  end

  test "a pending command logs outcome pending" do
    with_jobs do
      gating(custom_rule("task.before_submit"))
      task = ready_to_submit(@builder)
      command("submit", @builder, submit_params(task))
    end

    assert_equal [ "pending", "-", "-" ], line_of(@key).values_at(:outcome, :refusal, :rule)
  end

  test "line keeps milestone 2's fields and their order for a refusal with no rule" do
    request = T::Request.new(command: "claim", workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: @builder.id,
      key: "k-made-up", request_hash: nil, params: {})
    text = Leverage::CommandLog.line(request, T::Outcome.refused(T::Refusal.new(code: "not_eligible")), lock_wait: 0.001,
      writes: 0.002, total: 0.004, gate: 0.003)

    assert_equal "leverage.command command=claim caller=seat:#{@builder.id} key=k-made-up outcome=refused refusal=not_eligible " \
                 "lock_wait_ms=1.000 event_step_ms=2.000 transition_ms=4.000 gate_ms=3.000 rule=-", text
  end
end
