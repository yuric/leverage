require "test_helper"

class ActionsTest < ActiveSupport::TestCase
  A = Leverage::Actions

  setup do
    @scenario = Scenario.new
    @task = @scenario.finishing_task(holder: false, actions: [ { kind: "send" } ])
    @action = Action.find_by!(task_id: @task.id)
  end

  test "action writers enforce the contract matrix" do
    writers = {
      "action.approved" => ->(ctx) { A.approve(ctx, @action, by: [ "owner", @scenario.owner.id ]) },
      "action.stopped" => ->(ctx) { A.stop(ctx, @action, by: [ "owner", @scenario.owner.id ]) },
      "action.started" => ->(ctx) { A.start(ctx, @action) },
      "action.reported_done" => ->(ctx) { A.report_done(ctx, @action) },
      "action.marked_done" => ->(ctx) { A.mark_done(ctx, @action) },
      "action.waived" => ->(ctx) { A.waive(ctx, @action) }
    }
    machine = Leverage::Contract.state_machine.fetch("action_machine")
    writers.each do |type, write|
      machine.fetch("states").each do |state|
        @action.update!(state: state)
        ctx = @scenario.context
        move = machine.fetch("transitions").find do |row|
          row.fetch("event") == type && row.fetch("from").include?(state) && state != "stopped"
        end
        move ||= machine.fetch("transitions").find do |row|
          type == "action.waived" && row.fetch("event") == type && row.fetch("from").include?(state)
        end
        if move
          event = write.call(ctx)
          assert_equal type, event&.type
          assert_equal move.fetch("to"), @action.reload.state
        else
          assert_raises(ArgumentError) { write.call(ctx) }
          assert_equal state, @action.reload.state
        end
        Hold.where(task_id: @task.id).update_all(closed_at: ctx.at)
      end
    end
  end

  test "rework withdraws open decisions and cancel revokes remaining actions" do
    ctx = @scenario.context
    A.withdraw_open(ctx, @task)
    assert_equal "contracted", @action.reload.state
    assert_equal [ "action.withdrawn" ], ctx.events.map(&:type)
    A.revoke_open(ctx, @task)
    assert_equal "revoked", @action.reload.state
    assert_equal "action.revoked", ctx.events.last.type
  end

  test "waiving an action keeps its ended approval check and withdraws unsettled checks" do
    approval = @scenario.rule(key: "orchestrator_approves_actions", origin: "shipped")
    gate = @scenario.rule(hook: "action.requested")
    ended = @scenario.rule_check(@task, rule: approval, subject: @action, result: "error")
    waiting = @scenario.rule_check(@task, rule: approval, subject: @action)
    blocked = @scenario.rule_check(@task, rule: gate, subject: @action, result: "error")

    ctx = @scenario.context
    A.waive(ctx, @action)

    assert_equal "error", ended.reload.result
    assert_equal "withdrawn", waiting.reload.result
    assert_equal "withdrawn", blocked.reload.result
    assert_equal [ waiting.id, blocked.id ].sort, ctx.events.select { |event| event.type == "check.finished" }.map(&:subject_id).sort
  end

  test "contract definitions keep unchanged rows and return added and removed ids" do
    task = @scenario.task(state: "backlog")
    first = A.create_for(task, [ { kind: "send", description: "Sample notice" } ])
    assert_equal 1, first&.added_ids&.size
    assert_empty A.create_for(task, [ { kind: "send", description: "Sample notice" } ]).added_ids
    changed = A.create_for(task, [ { kind: "publish", description: "Sample page" } ])
    assert_equal first.added_ids, changed.removed_ids
    assert_equal changed.added_ids, Action.where(task_id: task.id).pluck(:id)
  end
end
