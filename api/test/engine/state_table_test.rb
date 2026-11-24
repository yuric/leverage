require "test_helper"

# Test 3 (PRD L836) for the task loop (milestone 2 plan WP3): for each of the
# seventeen commands of Transitions::Table::TASK_LOOP and every task state,
# the state_machine.json row's move and events, or invalid_state. The cases
# come from StateTableCases, so nothing here retypes the table.
#
# A command about a task that no seat holds in that state is also
# refused with a cause that ranks before invalid_state (not_holder, PRD
# L548); there the test asserts that invalid_state is among the entry's
# refusals and that the answer is the first by precedence. Claim and claim
# review name no task: from any state but their own there is nothing to
# claim, which is not_eligible (RC-50).
class StateTableTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  # The side events a decision of this milestone names on top of a row's
  # events (milestone 2 plan SC-11): cost.reported on a verdict (EN-12).
  SIDE_EVENTS = { "pass_review" => %w[cost.reported], "fail_review" => %w[cost.reported] }.freeze

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
    @owner = @scenario.owner
  end

  StateTableCases.define(self, T::Table::TASK_LOOP) do |kase|
    kase.invalid_state? ? assert_invalid_state(kase) : assert_row(kase)
  end

  %w[complete_contract edit_contract].each do |command|
    test "#{command} closes the budget hold when the cap rises above spend" do
      kase = StateTableCases.for([ command ]).find { |row| row.from == "backlog" }
      assert_includes kase.row.fetch("holds_closed"), "budget"
      task = task_in(kase.from)
      task.update!(budget_cap: 1, spent: 1)
      hold = @scenario.hold(task, reason: "budget")

      outcome = apply(command, @owner, contract_params(task).merge("budget_cap" => 2))
      assert outcome.completed?, outcome.refusal&.code

      events = Event.where(command_id: @key).order(:seq).to_a
      assert_equal [ kase.events.first, "hold.closed", "inbox.resolved", *kase.events.drop(1) ], events.map(&:type)
      assert_equal events.first.id, events.second.cause_id
      assert_equal "raise_cap", events.third.payload.fetch("choice")
      assert hold.reload.closed_at
      assert_equal [ kase.to, 2 ], [ task.reload.state, task.budget_cap ]
    end
  end

  private

  # Events a row's command writes before its own because it ends a waiting
  # command first (milestone 4 plan §2.1, rule 11): releasing a provisional
  # claim withdraws its running check and the check's job.
  CANCELLED_FIRST = { %w[release ready] => %w[check.finished job.withdrawn] }.freeze

  def assert_row(kase)
    caller, params, task = prepare(kase.command, kase.from, valid: true, guard: kase.guard)
    outcome = apply(kase.command, caller, params)
    assert outcome.completed?, "#{kase.name}: #{outcome.refusal&.code}"

    types = Event.where(command_id: @key).order(:seq).pluck(:type)
    first = CANCELLED_FIRST.fetch([ kase.command, kase.from ], [])
    first = %w[check.finished] if kase.guard.include?("escalates")
    last = SIDE_EVENTS.fetch(kase.command, [])
    last = finish_events(kase) if kase.from == "finishing"
    assert_equal first + kase.events + last, types
    assert_finishing_effects(kase, task) if kase.to == "finishing"
    task ||= Task.find(outcome.result.fetch("task_id")) if outcome.result&.key?("task_id")
    task ||= Task.find(outcome.result.dig("task", "id")) if outcome.result&.key?("task")
    task ||= Review.find(outcome.result.dig("review", "id")).then { |review| Task.find(review.task_id) } if outcome.result&.key?("review")
    assert_equal kase.to, task.reload.state if kase.to
  end

  def finish_events(kase)
    case kase.command
    when "release" then %w[hold.opened inbox.opened]
    when "cancel" then %w[action.revoked]
    else []
    end
  end

  def assert_finishing_effects(kase, task)
    case kase.command
    when "pass_review"
      action = Action.find_by!(task_id: task.id)
      assert_equal "requested", action.state
      assert Hold.exists?(task_id: task.id, action_id: action.id, reason: "owner_approval", closed_at: nil)
    when "release"
      assert_nil task.reload.holder_seat_id
      assert_nil task.lease_due_at
      assert_equal @builder.id, task.builder_seat_id
      assert Hold.exists?(task_id: task.id, reason: "action_unconfirmed", closed_at: nil)
    end
  end

  def assert_invalid_state(kase)
    caller, params, = prepare(kase.command, kase.from, valid: false)
    outcome = apply(kase.command, caller, params)
    assert outcome.refused?, kase.name

    if %w[claim claim_review].include?(kase.command)
      assert_equal "not_eligible", outcome.refusal.code, "nothing to claim from #{kase.from}"
      return
    end

    codes = refusal_codes(kase.command, caller, params)
    assert_includes codes, "invalid_state"
    assert_equal T::Precedence.first(codes).code, outcome.refusal.code
    assert_operator T::Precedence.rank(outcome.refusal.code), :<=, T::Precedence.rank("invalid_state")
  end

  def refusal_codes(command, caller, params)
    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = @scenario.context(request: request(command, caller, params))
      entry = T::Table.entry_for(command).new
      entry.load(ctx)
      entry.refusals(ctx).map { |refusal| refusal.is_a?(T::Refusal) ? refusal.code : refusal.to_s }
    end
  end

  # The caller, the params and the task for a command on a task in from.
  # valid: true also meets the row's other conditions (a held review, an
  # acknowledged briefing, every criterion passed).
  def prepare(command, from, valid:, guard: [])
    case command
    when "add_task" then [ @owner, add_task_params(guard.include?("adds_to_ideas") ? "ideas" : "backlog"), nil ]
    when "complete_contract" then [ @owner, contract_params(task_in(from)), task_in(from) ]
    when "cancel" then [ @owner, { "id" => task_in(from).id }, task_in(from) ]
    when "allow_another_round"
      task = task_in("working")
      hold_for_rounds(task) if valid
      [ @owner, { "id" => task.id }, task ]
    when "claim"
      task_in(from)
      [ @builder, {}, nil ]
    when "claim_review"
      task_in(from)
      [ @reviewer, {}, nil ]
    when "acknowledge_briefing"
      task = task_in(from)
      [ @builder, { "id" => task.id, "briefing_hash" => Leverage::Briefing.hash_for(task, seat: @builder) }, task ]
    when "heartbeat", "release"
      task = task_in(from || "working")
      claim_provisionally(task) if valid && command == "release" && from == "ready"
      params = { "id" => task.id }
      params["reason"] = "unable_to_continue" if command == "release"
      [ @builder, params, task ]
    when "start_criterion", "pass_criterion", "submit"
      task = task_in(from)
      acknowledge(task) if valid
      criterion = build_criterion(task)
      params = { "id" => task.id }
      case command
      when "start_criterion" then params["cid"] = criterion.id
      when "pass_criterion" then params.merge!("cid" => criterion.id, "evidence" => evidence)
      when "submit"
        pass_every_criterion(task) if valid
        params.merge!("handoff_note" => "A made-up handoff note.", "work_reference" => nil)
      end
      [ @builder, params, task ]
    else review_command(command, from, valid: valid, guard: guard)
    end
  end

  def review_command(command, from, valid:, guard:)
    task = if guard.include?("has_outward_action")
      @scenario.task(state: from, builder: @builder, actions: [ { kind: "send" } ])
    else
      task_in(from || "in_review")
    end
    if guard.include?("escalates")
      @scenario.seat(role: "builder", strength_rank: @builder.strength_rank + 1)
      @scenario.rule(key: "escalate_after_failed_reviews", origin: "shipped", parameters: { "threshold" => 1 })
    end
    review = open_review(task)
    acknowledge_review(task, review) if valid && %w[pass_review fail_review].include?(command)
    @scenario.task(state: "working", builder: @builder) if guard.include?("builder_busy")
    params = { "id" => review.id }
    case command
    when "acknowledge_review_briefing"
      params["briefing_hash"] = Leverage::Briefing.hash_for(task, seat: @reviewer, review: review)
    when "pass_review" then params.merge!(verdict("passed", []))
    when "fail_review" then params.merge!(verdict("failed", [ build_criterion(task).id ]))
    end
    [ @reviewer, params, task ]
  end

  def task_in(state)
    @task_in ||= {}
    @task_in[state] ||= if state == "finishing"
      @scenario.finishing_task(builder: @builder, reviewer: @reviewer, actions: [ { kind: "send", state: "approved" } ])
    else
      @scenario.task(state: state, builder: @builder, reviewer: @reviewer)
    end
  end

  # The task's open review, claimed by the reviewer when the task is In
  # review; any other state gets a review row nobody holds.
  def open_review(task)
    if task.state == "in_review"
      @scenario.review(task, reviewer: @reviewer)
    else
      Review.where(task_id: task.id).order(:round).last ||
        Review.create!(workspace_id: task.workspace_id, task_id: task.id, round: task.round)
    end
  end

  def build_criterion(task)
    Criterion.where(task_id: task.id, kind: "build").order(:position).first ||
      Criterion.create!(workspace_id: task.workspace_id, task_id: task.id, position: 1, kind: "build", text: "Made-up.")
  end

  def pass_every_criterion(task)
    Criterion.where(task_id: task.id, kind: "build").each do |criterion|
      apply("pass_criterion", @builder, "id" => task.id, "cid" => criterion.id, "evidence" => evidence)
    end
  end

  def acknowledge(task)
    return unless task.holder_seat_id == @builder.id

    apply("acknowledge_briefing", @builder, "id" => task.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: @builder))
  end

  def acknowledge_review(task, review)
    return unless review.reviewer_seat_id == @reviewer.id

    apply("acknowledge_review_briefing", @reviewer, "id" => review.id,
      "briefing_hash" => Leverage::Briefing.hash_for(task, seat: @reviewer, review: review))
  end

  # A provisional claim of a Ready task by the builder (RE-5): a model
  # gate at task.before_claim makes the claim wait on its check.
  def claim_provisionally(task)
    @scenario.rule(hook: "task.before_claim")
    outcome = apply("claim", @builder, {})
    assert_equal [ :pending, @builder.id ], [ outcome.outcome, task.reload.holder_seat_id ]
  end

  def hold_for_rounds(task)
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: task, reason: "rounds_exceeded", facts: { round: task.round })
    end
  end

  def add_task_params(state)
    { "title" => "A made-up task", "state" => state }
  end

  def contract_params(task)
    { "id" => task.id, "title" => task.title, "details" => nil,
      "criteria" => [ { "text" => "Made-up build criterion.", "kind" => "build" },
                      { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => nil }
  end

  def evidence = { "kind" => "link", "value" => "https://example.test/made-up-proof" }

  def verdict(value, failed)
    { "verdict" => value, "failed_criteria" => failed, "notes" => "Made-up notes.", "tokens" => 10, "spend" => 0.01 }
  end

  def request(command, caller, params, key: "key-#{SecureRandom.hex(6)}")
    T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: caller.is_a?(Seat) ? "seat" : "owner",
      caller_id: caller.id, key: key, request_hash: Digest::SHA256.hexdigest("#{command}#{params.to_json}"), params: params)
  end

  def apply(command, caller, params)
    built = request(command, caller, params)
    @key = built.key
    T.apply(built)
  end
end
