require "test_helper"

# The outcome of a command a seat sent (get_command; Reads::CommandOutcome;
# milestone 4 plan RE-3, rule 11, RC-17): a command that waits reads
# pending, and the same row reads what the transition became once it
# completed, was refused by a rule or was ended from outside. The row is
# the requester's: another caller's key, or another workspace's, is not
# found.
class CommandOutcomeReadTest < ActiveSupport::TestCase
  include OpenapiAssertions

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(role: "builder")
  end

  def row(**columns)
    Command.create!({ workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: @seat.id,
                      key: "key-#{SecureRandom.hex(6)}", command: "submit", request_hash: "made-up-hash",
                      outcome: "pending" }.merge(columns))
  end

  def read(command, caller_id: @seat.id, workspace_id: @scenario.workspace_id)
    Leverage::Reads::CommandOutcome.call(workspace_id: workspace_id, caller_kind: "seat", caller_id: caller_id,
      key: command.key)
  end

  def body(found) = JSON.parse(JSON.generate(RunsCommands.outcome_body(found.row.command, found.row.key, found.outcome)))

  test "a command that waits reads pending, with no result and no refusal" do
    found = read(row)

    assert_equal "pending", found.outcome.outcome.to_s
    assert_equal({ "outcome" => "pending", "result" => nil, "refusal" => nil }, body(found).slice("outcome", "result", "refusal"))
    assert_matches_component("CommandOutcome", body(found))
  end

  test "the same row reads completed with its result once its transition completed" do
    command = row
    command.update_columns(outcome: "completed", result: { "task" => { "state" => "in_review" } }, notify: true)

    found = read(command)

    assert_equal [ "completed", { "task" => { "state" => "in_review" } } ], [ found.outcome.outcome.to_s, found.outcome.result ]
    assert_matches_component("CommandOutcome", body(found))
  end

  test "a refusal by a rule reads blocked_by_rule with the rule and its reason, and an ending from outside its code" do
    rule_id = SecureRandom.uuid
    refused = row(outcome: "refused", refusal: { code: "blocked_by_rule", rule_id: rule_id, reason: "Made-up reason." })
    ended = row(outcome: "refused", refusal: { code: "task_cancelled", rule_id: nil, reason: nil })

    assert_equal({ "code" => "blocked_by_rule", "rule_id" => rule_id, "reason" => "Made-up reason." },
      body(read(refused))["refusal"])
    assert_equal({ "code" => "task_cancelled", "rule_id" => nil, "reason" => nil }, body(read(ended))["refusal"])
    [ refused, ended ].each { |command| assert_matches_component("CommandOutcome", body(read(command))) }
  end

  test "another caller's key and another workspace's are not found" do
    command = row
    other = @scenario.seat(role: "builder")

    assert_nil read(command, caller_id: other.id)
    assert_nil read(command, workspace_id: Scenario.new.workspace_id)
  end

  test "reading writes nothing" do
    command = row
    before = [ command.reload.attributes, Event.count ]

    read(command)

    assert_equal before, [ command.reload.attributes, Event.count ]
  end
end
