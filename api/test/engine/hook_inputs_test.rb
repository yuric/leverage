require "test_helper"

# Leverage::HookInputs, the one reading of the hashed inputs of each hook
# (PRD L410-L417; hooks.json hashed_inputs; milestone 4 plan §2.1 rule 1,
# WP1): one case per hook, each answering exactly the keys hooks.json
# names, in values Gating.input_hash accepts. The contract's own golden
# vectors (test/contract/gating_test.rb) fix the shapes: a submit's
# criteria are {id, state, evidence: [[kind, value], ...]} in order; a
# pass's evidence is keyed by criterion id.
class HookInputsTest < ActiveSupport::TestCase
  HookInputs = Leverage::HookInputs

  setup do
    @scenario = Scenario.new
  end

  def hooks = Leverage::Contract.hooks.fetch("hooks")

  def hashed_inputs(hook) = hooks.find { |entry| entry.fetch("hook") == hook }.fetch("hashed_inputs")

  def evidence(criterion, kind, value)
    Evidence.create!(workspace_id: @scenario.workspace_id, criterion_id: criterion.id, kind: kind, value: value,
      attached_by_seat_id: @task.holder_seat_id || @scenario.seat.id)
  end

  # Every hook of hooks.json, with what a command at it hands HookInputs.
  def every_hook
    @task = @scenario.task(state: "working")
    seat = @scenario.seat(role: "reviewer")
    review = Review.create!(workspace_id: @scenario.workspace_id, task_id: @task.id, round: 0)
    action = Action.create!(workspace_id: @scenario.workspace_id, task_id: @task.id, position: 1, kind: "publish",
      description: "Publish the made-up page.")
    {
      "task.before_ready" => { params: { "title" => "A task", "details" => nil, "criteria" => [ { "text" => "One.", "kind" => "build" } ],
                                         "actions" => [] } },
      "task.before_claim" => { params: {}, seat: seat },
      "task.before_submit" => { params: { "handoff_note" => "Done." } },
      "task.before_done" => { params: { "verdict" => "passed", "notes" => "Fine." }, review: review },
      "action.requested" => { params: { "aid" => action.id } },
      "review.assign" => { params: {}, seat: seat },
      "review.failed" => { params: {}, review: review },
      "question.asked" => { params: { "text" => "Which made-up page?" } },
      "cost.reported" => { params: { "event_id" => SecureRandom.uuid } }
    }
  end

  test "every hook answers exactly the keys hooks.json hashes, and Gating.input_hash accepts it" do
    cases = every_hook
    assert_equal hooks.map { |entry| entry.fetch("hook") }.sort, cases.keys.sort

    cases.each do |hook, given|
      inputs = HookInputs.for(hook: hook, task: @task, **given)
      assert_equal hashed_inputs(hook).sort, inputs.keys.sort, hook
      assert_match(/\A\h{64}\z/, Leverage::Gating.input_hash(hook: hook, inputs: inputs), hook)
    end
  end

  test "an unknown hook is refused" do
    task = @scenario.task
    assert_raises(ArgumentError) { HookInputs.for(hook: "task.before_lunch", task: task, params: {}) }
  end

  test "changing only the requested title changes the task.before_ready digest" do
    task = @scenario.task(title: "Stored title")
    hook = "task.before_ready"
    request = { "details" => "Work in the sample folder.", "criteria" => [], "actions" => [] }
    first = HookInputs.for(hook: hook, task: task, params: request.merge("title" => "Revise the sample"))
    second = HookInputs.for(hook: hook, task: task, params: request.merge("title" => "Replace the sample"))

    assert_equal "Revise the sample", first["title"]
    refute_equal Leverage::Gating.input_hash(hook: hook, inputs: first),
      Leverage::Gating.input_hash(hook: hook, inputs: second)
  end

  # Trace 07's Complete contract: the inputs are the requested contract,
  # not the stored one (rule 1). Its two checks at task.before_ready carry
  # the engine's own hash of those inputs (api/contract/README.md, A
  # check's identity), one digest in every event that names them, and that
  # is what Gating.input_hash gives for what HookInputs reads.
  test "task.before_ready hashes trace 07's requested contract, not the stored one" do
    trace = Leverage::Contract.trace("07-pending-gate-check-error-override")
    request = trace.fetch("commands").find { |command| command.fetch("command") == "complete_contract" }.fetch("body")
    digests = trace.fetch("commands").flat_map { |command| command.fetch("expect").fetch("events") }
      .map { |event| event.fetch("payload") }.select { |payload| payload["hook"] == "task.before_ready" }
      .map { |payload| payload.fetch("input_hash") }
    task = @scenario.task(state: "backlog", title: "A stored title", details: "Stored details.")

    inputs = HookInputs.for(hook: "task.before_ready", task: task, params: request)

    assert_equal({ "title" => "Update the pricing page",
                   "details" => "The page shows this year's prices.\n\nUse the figures in the brief.",
                   "criteria" => [ { "text" => "Criterion build of task 1 holds.", "kind" => "build" },
                                   { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
                   "actions" => [] }, inputs)
    assert_equal 4, digests.size, "the four check events of its two checks name task.before_ready"
    assert_equal [ Leverage::Gating.input_hash(hook: "task.before_ready", inputs: inputs) ], digests.uniq
  end

  test "task.before_ready keeps only text and kind of a criterion, kind and description of an action, in order" do
    task = @scenario.task
    inputs = HookInputs.for(hook: "task.before_ready", task: task, params: {
      "title" => "T.", "details" => "D.", "work_reference" => "~/not/hashed",
      "criteria" => [ { "kind" => "build", "text" => "B." }, { "text" => "R.", "kind" => "review", "extra" => 1 } ],
      "actions" => [ { "kind" => "publish", "description" => "P." } ]
    })
    assert_equal({ "title" => "T.", "details" => "D.",
                   "criteria" => [ { "text" => "B.", "kind" => "build" }, { "text" => "R.", "kind" => "review" } ],
                   "actions" => [ { "kind" => "publish", "description" => "P." } ] }, inputs)
  end

  test "task.before_claim is the contract version and the seat" do
    task = @scenario.task(state: "ready")
    seat = @scenario.seat
    inputs = HookInputs.for(hook: "task.before_claim", task: task, params: {}, seat: seat)

    assert_equal({ "contract_version" => 1, "seat_id" => seat.id }, inputs)
    assert_raises(ArgumentError) { HookInputs.for(hook: "task.before_claim", task: task, params: {}) }
  end

  test "task.before_submit is the version, each live criterion's id, state and evidence in order, and the requested note" do
    @task = @scenario.task(state: "working", criteria: %w[build build review])
    first, second, third = Criterion.where(task_id: @task.id).order(:position).to_a
    first.update!(state: "passed")
    evidence(first, "link", "https://example.test/one")
    evidence(first, "note", "Section 2.")
    second.update!(removed_at: Time.current)

    inputs = HookInputs.for(hook: "task.before_submit", task: @task, params: { "handoff_note" => "Done.\nSee \"notes\"." })

    assert_equal({ "contract_version" => 1, "handoff_note" => "Done.\nSee \"notes\".",
                   "criteria" => [ { "id" => first.id, "state" => "passed",
                                     "evidence" => [ [ "link", "https://example.test/one" ], [ "note", "Section 2." ] ] },
                                   { "id" => third.id, "state" => "open", "evidence" => [] } ] }, inputs)
  end

  test "task.before_done is the version, the requested verdict and notes, and the evidence by criterion" do
    @task = @scenario.task(state: "in_review")
    build = Criterion.find_by!(task_id: @task.id, kind: "build")
    evidence(build, "link", "https://example.test/proof")
    review = @scenario.review(@task)

    inputs = HookInputs.for(hook: "task.before_done", task: @task, review: review,
      params: { "verdict" => "passed", "notes" => "Looks right.", "failed_criteria" => [], "tokens" => 3, "spend" => 0 })

    assert_equal({ "contract_version" => 1, "verdict" => "passed", "notes" => "Looks right.",
                   "evidence" => { build.id => [ [ "link", "https://example.test/proof" ] ] } }, inputs)
  end

  test "the policy hooks hash their subject: the seat, the review, the question, the cost event" do
    task = @scenario.task(state: "in_review")
    seat = @scenario.seat(role: "reviewer")
    review = Review.find_by!(task_id: task.id)
    event_id = SecureRandom.uuid

    assert_equal({ "seat_id" => seat.id }, HookInputs.for(hook: "review.assign", task: task, params: {}, seat: seat))
    assert_equal({ "review_id" => review.id }, HookInputs.for(hook: "review.failed", task: task, params: {}, review: review))
    assert_equal({ "question" => "Which page?" },
      HookInputs.for(hook: "question.asked", task: task, params: { "text" => "Which page?", "blocking" => false }))
    assert_equal({ "event_id" => event_id }, HookInputs.for(hook: "cost.reported", task: task, params: { "event_id" => event_id }))
  end

  test "action.requested is the version and the named action's kind and description" do
    task = @scenario.task(state: "working")
    action = Action.create!(workspace_id: @scenario.workspace_id, task_id: task.id, position: 1, kind: "send",
      description: "Send the made-up note.")

    assert_equal({ "contract_version" => 1, "action_kind" => "send", "action_description" => "Send the made-up note." },
      HookInputs.for(hook: "action.requested", task: task, params: { "id" => task.id, "aid" => action.id }))
    assert_raises(ArgumentError) { HookInputs.for(hook: "action.requested", task: task, params: { "aid" => SecureRandom.uuid }) }
  end

  test "it reads only: no row and no event is written" do
    cases = every_hook
    counts = -> { [ Event.count, Task.count, Criterion.count, Evidence.count, Review.count ] }
    before = counts.call
    cases.each { |hook, given| HookInputs.for(hook: hook, task: @task, **given) }
    assert_equal before, counts.call
  end
end
