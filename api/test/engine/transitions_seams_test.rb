require "test_helper"
require_relative "entries/call_spy"

# Two seams in transitions.rb that the other packages of milestone 4 build
# against while WP4 changes the rest of the file (milestone 4 plan §4, the
# hand-over table; RE-6; WP4 owns this file afterwards):
#
# - Transitions.run_as(ctx, command, requester:, key:, params:): how one
#   command runs another entry as someone else inside its own transaction
#   (a planner's draft result runs Complete contract as the planner, with
#   the result call's key). WP4 wrote it: the entry's refusals, gate and
#   perform as the requester (pending_transitions_test.rb holds the gate's
#   part).
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

  test "run_as performs the named entry as the requester, with its key, inside the caller's transaction" do
    planner = @scenario.seat(role: "planner")
    task = @scenario.task(state: "backlog")
    ctx = @scenario.context
    answer = T.run_as(ctx, "complete_contract", requester: planner, key: "k-planner-result",
      params: { "id" => task.id, "title" => "Made-up title", "goal" => "Made-up goal.",
                "criteria" => [ { "text" => "Made-up.", "kind" => "build" }, { "text" => "Agreed.", "kind" => "review" } ],
                "actions" => [] })

    assert_equal :completed, answer
    assert_equal %w[task.contract_changed task.ready], ctx.events.map(&:type)
    ctx.events.each { |event| assert_equal [ "seat", planner.id, "k-planner-result" ], [ event.actor_kind, event.actor_id, event.command_id ] }
    assert_equal "app", ctx.actor.first, "the caller comes back after it"
    assert_equal 0, Command.where(key: "k-planner-result").count, "the caller's command stores the row, not run_as"
  end

  test "run_as answers refused when the entry refuses, and writes nothing" do
    ctx = @scenario.context
    answer = T.run_as(ctx, "complete_contract", requester: @scenario.seat(role: "planner"), key: "k-late",
      params: { "id" => @scenario.task(state: "ready").id, "criteria" => [ { "text" => "Agreed.", "kind" => "review" } ] })

    assert_equal :refused, answer
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
  test "Finishing sees the command once after it performs and does not run again for a repeated key" do
    calls = nil
    T::Table.with_entries("add_task" => OneEvent) do
      repeated = request(key: "k-finishing-repeat")
      calls = spy_on(Leverage::Finishing, :after_command) do
        assert T.apply(repeated).completed?
        assert T.apply(repeated).completed?
      end
    end

    assert_equal 1, calls.size
    ctx = calls.sole.arguments.sole
    assert_equal [ "k-finishing-repeat", %w[task.created] ], [ ctx.request.key, ctx.events.map(&:type) ]
  end

  test "Finishing runs after an inline timer and the refused command, once each" do
    task = @scenario.task(state: "working", builder: @scenario.seat(role: "builder"))
    @scenario.make_due(task)
    refused = request.with(params: { "id" => task.id })
    observations = []
    original = Leverage::Finishing.method(:after_command)
    Leverage::Finishing.define_singleton_method(:after_command) do |ctx|
      observations << [ ctx.request.command, ctx.request.key, Task.find(task.id).state ]
      original.call(ctx)
    end

    T::Table.with_entries("add_task" => Refused) { assert T.apply(refused).refused? }

    assert_equal [ [ "builder_lease_expiry", nil, "ready" ], [ "add_task", refused.key, "ready" ] ], observations
  ensure
    Leverage::Finishing.define_singleton_method(:after_command, original) if original
  end

  test "a sweep timer command calls Finishing once after its entry, with no key" do
    task = @scenario.task(state: "working", builder: @scenario.seat(role: "builder"))
    @scenario.make_due(task)
    calls = spy_on(Leverage::Finishing, :after_command) do
      assert Leverage::Sweep.timer(@scenario.workspace_id, "builder_lease_expiry", "id" => task.id).completed?
    end

    assert_equal 1, calls.size
    ctx = calls.sole.arguments.sole
    assert_equal [ "builder_lease_expiry", nil ], [ ctx.request.command, ctx.request.key ]
    assert_includes ctx.events.map(&:type), "task.lease_expired"
  end

end
