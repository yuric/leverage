require "test_helper"
require_relative "call_spy"
require_relative "owner_controls_support"

# Edit contract (PRD Lifecycle L81, L82, Contract edits L205; milestone 3
# plan HE-25, HE-29; SC-3): in the Backlog task.contract_changed alone;
# from Ready, Working and In review the builder's lease and any review
# lease end with no event of their own, task.contract_changed then
# task.returned are written and the task is back in the Backlog with no
# holder and no builder; then the holds a contract edit answers close, and
# the seat-bound ones (Holds.close_seat_bound), each item resolved with the
# choice edit_contract where the item offers it. An owner_hold stays. The
# criteria keep their identity by position and kind (ContractDiff); the
# round is kept. Ideas, Finishing, Done and Cancelled are
# invalid_state.
class EditContractTest < ActiveSupport::TestCase
  include CallSpy
  include OwnerControlsSupport

  FIELDS = %w[contract_version minimum_strength_rank added_criterion_ids reset_criterion_ids removed_criterion_ids
              added_action_ids removed_action_ids].freeze

  setup do
    use_scenario
    @builder = scenario.seat(role: "builder", credential: scenario.credential)
  end

  def criteria_of(task) = Criterion.where(task_id: task.id, removed_at: nil).order(:position).to_a

  # The body that keeps the task's criteria, with changes by position.
  def body(task, changes = {}, **fields)
    criteria = criteria_of(task).map { |criterion| { "text" => criterion.text, "kind" => criterion.kind } }
    criteria = [ { "text" => "A made-up build criterion.", "kind" => "build" },
                 { "text" => "An independent reviewer agrees.", "kind" => "review" } ] if criteria.empty?
    changes.each { |index, text| criteria[index] = criteria[index].merge("text" => text) }
    { "id" => task.id, "title" => "A made-up edited title", "details" => "A made-up edited description.",
      "criteria" => criteria, "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil,
      "work_reference" => "~/work/made-up-edited" }.merge(fields.transform_keys(&:to_s))
  end

  def edit(task, changes = {}, **fields) = owner_run("edit_contract", body(task, changes, **fields))

  test "in the Backlog with no criteria yet: task.contract_changed alone, every criterion added" do
    task = scenario.task(state: "backlog")
    outcome, events = edit(task)

    assert_completed(outcome)
    assert_nil outcome.result
    event = events.sole
    added = criteria_of(task)
    assert_equal [ "task.contract_changed", "owner", scenario.owner.id ], [ event.type, event.actor_kind, event.actor_id ]
    assert_equal FIELDS.sort, event.payload.keys.sort
    assert_equal({ "contract_version" => 1, "minimum_strength_rank" => nil, "added_criterion_ids" => added.map(&:id),
                   "reset_criterion_ids" => [], "removed_criterion_ids" => [], "added_action_ids" => [],
                   "removed_action_ids" => [] }, event.payload)
    task.reload
    assert_equal [ "backlog", "A made-up edited title", "A made-up edited description.", "~/work/made-up-edited", 1 ],
      task.attributes.values_at("state", "title", "details", "work_reference", "contract_version")
  end

  test "in the Backlog with criteria: kept, reset and added by position and kind, and the minimum rank recorded" do
    task = scenario.task(state: "ready", criteria: %w[build build review])
    owner_run("edit_contract", body(task))
    kept, changed, review = criteria_of(task)
    new_body = body(task, { 1 => "The second criterion, changed." }, minimum_strength_rank: 2)
    new_body["criteria"].insert(2, { "text" => "A new build criterion.", "kind" => "build" })
    outcome, events = owner_run("edit_contract", new_body)

    assert_completed(outcome)
    payload = events.sole.payload
    now = criteria_of(task)
    assert_equal [ kept.id, changed.id ], now.first(2).map(&:id)
    assert_equal [ changed.id ], payload.fetch("reset_criterion_ids")
    assert_equal now.last(2).map(&:id), payload.fetch("added_criterion_ids")
    assert_equal [ review.id ], payload.fetch("removed_criterion_ids")
    assert_equal [ 3, 2 ], [ payload.fetch("contract_version"), payload.fetch("minimum_strength_rank") ]
    assert_equal 2, task.reload.minimum_strength_rank
  end

  test "from Working: the lease ends with no event of its own, then task.contract_changed and task.returned" do
    task = working_task(@builder)
    outcome, events = edit(task)

    assert_completed(outcome)
    assert_equal %w[task.contract_changed task.returned], events.map(&:type)
    returned = events.last
    assert_equal [ "owner", scenario.owner.id, {} ], [ returned.actor_kind, returned.actor_id, returned.payload ]
    task.reload
    assert_equal [ "backlog", nil, nil, nil, nil, nil ],
      task.attributes.values_at("state", "holder_seat_id", "builder_seat_id", "lease_due_at",
        "lease_time_left_while_paused", "resume_pending_since")
  end

  test "the builder's next call on the task is not_holder, and it is free at once" do
    task = working_task(@builder)
    edit(task)

    request = T::Request.new(command: "heartbeat", workspace_id: scenario.workspace_id, caller_kind: "seat",
      caller_id: @builder.id, key: new_key, request_hash: "made-up", params: { "id" => task.id })
    assert_refused("not_holder", T.apply(request))
    scenario.task(state: "ready")
    assert Leverage::Eligibility.may_claim?(@builder.reload, :task)
  end

  test "an unchanged passed criterion stays passed with its evidence; a changed one is reset to open" do
    task = working_task(@builder, criteria: %w[build build review])
    first, second, = criteria_of(task)
    [ first, second ].each do |criterion|
      criterion.update!(state: "passed", passed_at: scenario.database_now, passed_by_seat_id: @builder.id)
      Evidence.create!(workspace_id: task.workspace_id, criterion_id: criterion.id, kind: "link",
        value: "https://example.test/made-up-proof", attached_by_seat_id: @builder.id)
    end
    outcome, events = edit(task, { 1 => "The second criterion, changed." })

    assert_completed(outcome)
    assert_equal [ second.id ], events.first.payload.fetch("reset_criterion_ids")
    assert_equal "passed", first.reload.state
    assert_equal 1, Evidence.where(criterion_id: first.id).count
    assert_equal [ "open", "The second criterion, changed." ], second.reload.attributes.values_at("state", "text")
  end

  test "from In review: the review lease ends and the reviewer is free" do
    reviewer = scenario.seat(role: "reviewer", credential: scenario.credential(provider: "codex"))
    task = scenario.task(state: "in_review", builder: @builder)
    review = scenario.review(task, reviewer: reviewer)
    outcome, events = edit(task)

    assert_completed(outcome)
    assert_equal %w[task.contract_changed task.returned], events.map(&:type)
    assert_equal [ nil, nil, nil, nil ],
      review.reload.attributes.values_at("reviewer_seat_id", "lease_due_at", "lease_time_left_while_paused", "verdict")
    assert_equal [ "backlog", nil ], task.reload.attributes.values_at("state", "builder_seat_id")
    assert Leverage::Eligibility.may_claim?(reviewer.reload, :review)
  end

  test "from Ready: task.contract_changed and task.returned" do
    task = scenario.task(state: "ready")
    outcome, events = edit(task)

    assert_completed(outcome)
    assert_equal %w[task.contract_changed task.returned], events.map(&:type)
    assert_equal "backlog", task.reload.state
  end

  test "an edit answers Past the round limit: hold.closed, then inbox.resolved with edit_contract; the round is kept" do
    task = working_task(@builder)
    task.update_columns(round: 3)
    hold = open_hold(task.reload, "rounds_exceeded", facts: { round: 3 })
    outcome, events = edit(task)

    assert_completed(outcome)
    assert_equal %w[task.contract_changed task.returned hold.closed inbox.resolved], events.map(&:type)
    closed, resolved = events.last(2)
    assert_equal [ "owner", scenario.owner.id, hold.id, nil ],
      [ closed.actor_kind, closed.actor_id, closed.subject_id, closed.cause_id ]
    assert_equal({ "reason" => "rounds_exceeded", "rule_id" => nil, "credential_id" => nil, "lease_seat_id" => nil,
                   "wait_cause" => nil }, closed.payload)
    assert_equal [ "owner", { "choice" => "edit_contract" } ], [ resolved.actor_kind, resolved.payload ]
    assert events.all? { |event| event.round == 3 }
    assert_equal [ 3, 0 ], task.reload.attributes.values_at("round", "extra_rounds")
    assert_equal "resolved", InboxItem.find_by!(hold_id: hold.id).state
  end

  test "an owner_hold stays open: only Resume closes it" do
    task = working_task(@builder)
    owner_run("hold", "id" => task.id)
    outcome, events = edit(task)

    assert_completed(outcome)
    assert_equal %w[task.contract_changed task.returned], events.map(&:type)
    assert_equal %w[owner_hold], open_holds(task).map(&:reason)
  end

  test "from Working it closes the seat-bound holds through Holds.close_seat_bound, caused by task.returned" do
    task = working_task(@builder)
    open_hold(task, "seat_paused")
    events = nil
    calls = recording(Leverage::Holds, :close_seat_bound) { _, events = edit(task) }

    returned = events.find { |event| event.type == "task.returned" }
    args, keywords = calls.sole
    assert_equal [ task.id, returned.id, nil ], [ args[1].id, keywords[:cause].id, keywords[:wait_cause] ]
    assert_equal({ cause: keywords[:cause], wait_cause: nil }, keywords)
  end

  test "in the Backlog nothing is seat-bound: Holds.close_seat_bound is not called" do
    task = scenario.task(state: "backlog")
    calls = recording(Leverage::Holds, :close_seat_bound) { edit(task) }

    assert_empty calls
  end

  test "in the Backlog it closes contract_incomplete, which has no item" do
    task = scenario.task(state: "backlog")
    hold = open_hold(task, "contract_incomplete")
    outcome, events = edit(task)

    assert_completed(outcome)
    assert_equal %w[task.contract_changed hold.closed], events.map(&:type)
    assert hold.reload.closed_at
  end

  test "Ideas, Done and Cancelled are invalid_state and write nothing" do
    %w[ideas done cancelled].each do |state|
      task = scenario.task(state: state)
      outcome, events = edit(task)

      assert_refused("invalid_state", outcome)
      assert_empty events, state
      assert_equal state, task.reload.state
    end
  end

  test "Finishing is invalid_state (L205)" do
    task = scenario.finishing_task(builder: @builder)
    outcome, events = edit(task, actions: [ { "kind" => "publish", "description" => "Publish the prices." } ])

    assert_refused("invalid_state", outcome)
    assert_empty events
  end

  test "editing the contract records its ordered outward actions" do
    task = scenario.task(state: "backlog")
    outcome, events = edit(task, actions: [ { "kind" => "send", "description" => "Send the update." },
                                           { "kind" => "publish", "description" => "Publish the prices." } ])

    assert_completed(outcome)
    actions = Action.where(task_id: task.id).order(:position)
    assert_equal [ [ 1, "send", "contracted" ], [ 2, "publish", "contracted" ] ], actions.pluck(:position, :kind, :state)
    assert_equal actions.map(&:id), events.sole.payload.fetch("added_action_ids")
    assert_empty events.sole.payload.fetch("removed_action_ids")
  end

  test "editing the contract records the identities of replaced outward actions" do
    task = scenario.task(state: "backlog")
    unchanged = { "kind" => "send", "description" => "Send the update." }
    original = { "kind" => "publish", "description" => "Publish all prices." }
    assert_completed(edit(task, actions: [ unchanged, original ]).first)
    keep, remove = Action.where(task_id: task.id).order(:position).to_a

    outcome, events = edit(task, actions: [ unchanged, original.merge("description" => "Publish changed prices.") ])

    assert_completed(outcome)
    active = Action.where(task_id: task.id, state: "contracted").order(:position).to_a
    assert_equal [ [ 1, "Send the update." ], [ 2, "Publish changed prices." ] ],
      active.map { |action| [ action.position, action.description ] }
    assert_equal keep.id, active.first.id
    refute_equal remove.id, active.last.id
    assert_equal [ active.last.id ], events.sole.payload.fetch("added_action_ids")
    assert_equal [ remove.id ], events.sole.payload.fetch("removed_action_ids")
  end

  test "editing the contract applies the saved cap through Costs (AE-12)" do
    task = scenario.task(state: "backlog")
    task.update!(budget_cap: 5, spent: 6)
    hold = open_hold(task, "budget")
    outcome = nil
    calls = spy_on(Leverage::Costs, :cap_changed) do
      outcome, = edit(task, budget_cap: 4)
    end

    assert_completed(outcome)
    assert_equal [ [ task.id, BigDecimal("4") ] ], calls.map { |call| [ call.arguments.last.id, call.arguments.last.budget_cap ] }
    assert_nil hold.reload.closed_at
  end

  test "criteria that do not end with the one review are 422 invalid" do
    task = scenario.task(state: "backlog")
    criteria = [ { "text" => "Made-up review.", "kind" => "review" }, { "text" => "Made-up build.", "kind" => "build" } ]
    assert_raises(T::Invalid) { owner_run("edit_contract", body(task).merge("criteria" => criteria)) }
  end

  test "a work reference with sign-in details is 422 invalid" do
    task = scenario.task(state: "backlog")
    assert_raises(T::Invalid) do
      owner_run("edit_contract", body(task, work_reference: "https://made-up-user:made-up-secret@example.test/work"))
    end
  end

  test "an unknown task is not found" do
    assert_raises(T::NotFound) { owner_run("edit_contract", body(scenario.task).merge("id" => SecureRandom.uuid)) }
  end
end
