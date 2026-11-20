require "test_helper"
require_relative "entries/call_spy"

# Two seams in transitions.rb that the other packages of milestone 4 build
# against while WP4 changes the rest of the file (milestone 4 plan §4, the
# hand-over table; RE-6; WP4 owns this file afterwards):
#
# - Transitions.run_as(ctx, command, requester:, key:, params:): how one
#   command runs another entry as someone else inside its own transaction
#   (a planner's draft result runs Complete contract as the planner, with
#   the result call's key). Its first version does nothing and answers
#   :completed.
# - After a command's perform, ReviewerEligibility.after_command(ctx,
#   entry) is called once, with the entry (WP9 fills the method; trace 02's
#   replay needs the call).
class TransitionsSeamsTest < ActiveSupport::TestCase
  include CallSpy
  T = Leverage::Transitions

  # Writes one event, so the command has something to commit.
  class OneEvent < Leverage::Transitions::Entry
    def perform(ctx)
      task = Task.create!(workspace_id: ctx.workspace.id, state: "backlog")
      ctx.emit("task.created", task: task, payload: { state: "backlog" })
      @result = { "task_id" => task.id }
    end
  end

  # Refused before it performs.
  class Refused < Leverage::Transitions::Entry
    def refusals(_ctx) = [ "invalid_state" ]
    def perform(_ctx) = raise("a refused command must not perform")
  end

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
  end

  def request(key: "k-#{SecureRandom.hex(4)}")
    T::Request.new(command: "add_task", workspace_id: @scenario.workspace_id, caller_kind: "owner", caller_id: @owner.id,
      key: key, request_hash: "made-up-hash", params: {})
  end

  test "run_as has its final arguments" do
    assert_equal [ [ :req, :ctx ], [ :req, :command ], [ :keyreq, :requester ], [ :keyreq, :key ], [ :keyreq, :params ] ],
      T.method(:run_as).parameters
  end

  test "run_as's first version writes nothing and answers :completed" do
    planner = @scenario.seat(role: "planner")
    task = @scenario.task(state: "backlog")
    ctx = @scenario.context
    answer = T.run_as(ctx, "complete_contract", requester: planner, key: "k-planner-result",
      params: { "id" => task.id, "title" => "Made-up title" })

    assert_equal :completed, answer
    assert_empty ctx.events
  end

  test "after perform, ReviewerEligibility.after_command is called once, with the context and the entry" do
    calls = nil
    T::Table.with_entries("add_task" => OneEvent) do
      calls = spy_on(Leverage::ReviewerEligibility, :after_command) { assert T.apply(request).completed? }
    end

    assert_equal 1, calls.size
    ctx, entry = calls.sole.arguments
    assert_kind_of T::Context, ctx
    assert_instance_of OneEvent, entry
    assert_equal "add_task", entry.command
    assert_equal 1, ctx.events.size, "it comes after perform's events"
  end

  test "a refused command, and a repeat of a key, do not call it" do
    calls = []
    T::Table.with_entries("add_task" => Refused) do
      calls += spy_on(Leverage::ReviewerEligibility, :after_command) { assert T.apply(request).refused? }
    end
    T::Table.with_entries("add_task" => OneEvent) do
      repeated = request(key: "k-repeated")
      T.apply(repeated)
      calls += spy_on(Leverage::ReviewerEligibility, :after_command) { assert T.apply(repeated).completed? }
    end

    assert_empty calls
  end
end
