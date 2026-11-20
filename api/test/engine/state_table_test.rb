require "test_helper"

# Test 3 (PRD L836) for the task loop (milestone 2 plan WP3): for each of the
# seventeen commands of Transitions::Table::TASK_LOOP and every task state,
# the state_machine.json row's move and events, or invalid_state. The cases
# come from StateTableCases, so nothing here retypes the table.
#
# A row milestone 2 cannot reach is named with the decision that says so and
# skipped. A command about a task that no seat holds in that state is also
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
    reason = not_served(kase)
    skip "not reachable in milestone 2: #{reason}" if reason

    kase.invalid_state? ? assert_invalid_state(kase) : assert_row(kase)
  end

  private

  # Why a case cannot be reached in milestone 2, or nil.
  def not_served(kase)
    return "Finishing needs an outward action (SC-3)" if kase.from == "finishing"
    return "no rule escalates (EN-5)" if kase.guard.include?("escalates")
    return "an outward action (SC-3)" if kase.guard.include?("has_outward_action")
    return "a provisional claim needs a model check at task.before_claim (EN-5)" if kase.command == "release" && kase.from == "ready" && !kase.invalid_state?

    nil
  end

  def assert_row(kase)
    if kase.guard.include?("adds_to_imaginarium")
      error = assert_raises(T::Invalid) { apply("add_task", @owner, add_task_params("imaginarium")) }
      assert_match(/Imaginarium/i, error.message, "SC-4: only Promote takes a task out of the Imaginarium")
      return
    end

    caller, params, task = prepare(kase.command, kase.from, valid: true, guard: kase.guard)
    outcome = apply(kase.command, caller, params)
    assert outcome.completed?, "#{kase.name}: #{outcome.refusal&.code}"

    types = Event.where(command_id: @key).order(:seq).pluck(:type)
    assert_equal kase.events + SIDE_EVENTS.fetch(kase.command, []), types
    task ||= Task.find(outcome.result.fetch("task_id")) if outcome.result&.key?("task_id")
    task ||= Task.find(outcome.result.dig("task", "id")) if outcome.result&.key?("task")
    task ||= Review.find(outcome.result.dig("review", "id")).then { |review| Task.find(review.task_id) } if outcome.result&.key?("review")
    assert_equal kase.to, task.reload.state if kase.to
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
    when "add_task" then [ @owner, add_task_params("backlog"), nil ]
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
    task = task_in(from || "in_review")
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
    @task_in[state] ||= @scenario.task(state: state, builder: @builder, reviewer: @reviewer)
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

  def hold_for_rounds(task)
    ActiveRecord::Base.transaction(requires_new: true) do
      Leverage::Holds.open(@scenario.context, task: task, reason: "rounds_exceeded", facts: { round: task.round })
    end
  end

  def add_task_params(state)
    { "title" => "A made-up task", "goal" => "A made-up goal.", "state" => state }
  end

  def contract_params(task)
    { "id" => task.id, "title" => task.title, "goal" => task.goal, "details" => nil,
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
