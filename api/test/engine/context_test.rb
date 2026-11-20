require "test_helper"

# Transitions::Context#as_requester (milestone 4 plan §2.1, RE-3, WP1): a
# pending transition completes, is refused or is cancelled inside whatever
# command or timer brings its last result, and the events it writes there
# carry its requester as actor, the requester's key as command_id and the
# check.finished or check.overridden that settled it as cause_id (L241,
# trace 07 events 14 and 15). Inside the block the context answers as the
# requester's command does: actor and request.key are the requester's, so
# Holds, Leases and every other writer that reads them follow too.
class TransitionContextTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
    @builder = @scenario.seat(role: "builder")
    @task = @scenario.task(state: "working", builder: @builder)
  end

  # The owner's command whose context the test writes in.
  def owner_context(key: "k-owner-override")
    request = T::Request.new(command: "override_check", workspace_id: @scenario.workspace_id, caller_kind: "owner",
      caller_id: @owner.id, key: key, request_hash: "made-up-hash", params: { "reason" => "Made-up reason." })
    @scenario.context(request: request)
  end

  def promoted(ctx, **fields) = ctx.emit("task.changed", task: @task, payload: { priority: "normal", project_id: nil, budget_cap: nil }, **fields)

  test "an event written inside carries the requester, its key and the cause; outside, the caller's" do
    pending = @scenario.pending_transition(@task, command: "submit", requester: @builder, key: "k-builder-submit",
      params: { "handoff_note" => "Made-up note." })
    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = owner_context
      cause = promoted(ctx)
      before = promoted(ctx)
      inside = ctx.as_requester(pending, cause_id: cause.id) { promoted(ctx) }
      after = promoted(ctx)

      assert_equal [ "owner", @owner.id, "k-owner-override", nil ],
        [ before.actor_kind, before.actor_id, before.command_id, before.cause_id ]
      assert_equal [ "seat", @builder.id, "k-builder-submit", cause.id ],
        [ inside.actor_kind, inside.actor_id, inside.command_id, inside.cause_id ]
      assert_equal [ "owner", @owner.id, "k-owner-override", nil ],
        [ after.actor_kind, after.actor_id, after.command_id, after.cause_id ]
      assert_equal [ ctx.at ] * 3, [ before.at, inside.at, after.at ]
      assert_equal [ cause, before, inside, after ].map(&:id), ctx.events.map(&:id)
    end
  end

  test "inside, the context answers as the requester's command: actor, key, command and params" do
    pending = @scenario.pending_transition(@task, command: "submit", requester: @builder, key: "k-builder-submit",
      params: { "handoff_note" => "Made-up note.", "work_reference" => nil })
    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = owner_context
      seen = ctx.as_requester(pending, cause_id: nil) do
        [ ctx.actor, ctx.request.key, ctx.request.caller_kind, ctx.request.caller_id, ctx.request.command,
          ctx.request.params, ctx.request.by_app? ]
      end

      assert_equal [ [ "seat", @builder.id ], "k-builder-submit", "seat", @builder.id, "submit",
                     { "handoff_note" => "Made-up note.", "work_reference" => nil }, false ], seen
      assert_equal [ [ "owner", @owner.id ], "k-owner-override", "override_check" ],
        [ ctx.actor, ctx.request.key, ctx.request.command ]
    end
  end

  test "an owner requester is the owner, also inside a timer the app runs" do
    pending = @scenario.pending_transition(@task, command: "complete_contract", requester: @owner, key: "k-owner-complete")
    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = @scenario.context
      inside = ctx.as_requester(pending, cause_id: nil) { promoted(ctx) }

      assert_equal [ "owner", @owner.id, "k-owner-complete" ], [ inside.actor_kind, inside.actor_id, inside.command_id ]
      assert_equal [ "app", nil, nil ], ctx.actor + [ ctx.request.key ]
    end
  end

  test "a cause named on the event wins, and the block's value is answered" do
    pending = @scenario.pending_transition(@task, command: "submit", requester: @builder, key: "k-builder-submit")
    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = owner_context
      cause = promoted(ctx)
      other = promoted(ctx)
      answer = ctx.as_requester(pending, cause_id: cause.id) { [ promoted(ctx, cause_id: other.id), :done ] }

      assert_equal other.id, answer.first.cause_id
      assert_equal :done, answer.last
    end
  end

  test "the caller's identity comes back when the block raises" do
    pending = @scenario.pending_transition(@task, command: "submit", requester: @builder, key: "k-builder-submit")
    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = owner_context
      assert_raises(RuntimeError) { ctx.as_requester(pending, cause_id: nil) { raise "made-up failure" } }

      assert_equal [ [ "owner", @owner.id ], "k-owner-override" ], [ ctx.actor, ctx.request.key ]
      assert_nil promoted(ctx).cause_id
    end
  end
end
