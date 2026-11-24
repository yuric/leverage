require "test_helper"
require_relative "../engine/entries/jobs_support"

# The board card's milestone 4 fields (get_board; milestone 4 plan §2.3,
# RD-27): checking, while a transition of the task is pending and no hold
# is open ("Checking the details"), and check_reason, the reason of the
# failed check behind an open contract_incomplete hold ("Needs details").
# Read from the rows Scenario builds through Reads::Board (a Snapshot:
# CommittingTestCase) and held to openapi.json's BoardTask.
class BoardReadTest < CommittingTestCase
  include JobsSupport
  include OpenapiAssertions

  def board
    json = JSON.parse(JSON.generate(Leverage::Reads::Board.call(scenario.workspace_id)))
    json.fetch("tasks").each { |card| assert_matches_component("BoardTask", card) }
    json
  end

  def card(task) = board.fetch("tasks").find { |candidate| candidate.dig("task", "id") == task.id }

  def page(task) = JSON.parse(JSON.generate(Leverage::Reads::TaskPage.call(scenario.workspace_id, task.id)))

  def owner = scenario.owner

  # A Backlog task whose Complete contract waits on a model check: the
  # owner's request is stored, the task stays in Backlog (RE-2).
  def checking_task
    task = scenario.task(state: "backlog")
    [ task, scenario.pending_transition(task, command: "complete_contract", requester: owner,
      params: { "goal" => "A made-up goal." }) ]
  end

  test "a card is checking while a transition of its task is pending and no hold is open" do
    task, = checking_task
    quiet = scenario.task(state: "backlog")

    assert_equal true, card(task)["checking"]
    assert_equal false, card(quiet)["checking"]
  end

  test "a card is not checking while a hold is open on the task, nor once the transition is no longer pending" do
    task, pending = checking_task
    hold = scenario.hold(task, reason: "check_error", item: false)
    assert_equal false, card(task)["checking"], "the hold's waiting step is open, not check (L378)"

    ActiveRecord::Base.transaction { Leverage::Holds.close(scenario.context, hold: hold, task: task) }
    assert_equal true, card(task)["checking"]

    pending.update_columns(state: "completed", params: nil)
    assert_equal false, card(task)["checking"]
  end

  test "check_reason is the reason of the failed check behind an open contract_incomplete hold, and null otherwise" do
    rule = scenario.rule(hook: "task.before_ready")
    task = scenario.task(state: "backlog")
    check = scenario.rule_check(task, rule: rule, result: "failed", reason: "Made-up reason: say what done looks like.")
    other = scenario.task(state: "backlog")
    assert_nil card(task)["check_reason"]

    hold = scenario.hold(task, reason: "contract_incomplete", item: false)
    hold.update_columns(rule_id: rule.id, rule_check_id: check.id)
    owner_hold = scenario.hold(other, reason: "owner_hold", item: false)
    owner_hold.update_columns(rule_id: rule.id, rule_check_id: check.id)

    assert_equal "Made-up reason: say what done looks like.", card(task)["check_reason"]
    assert_nil card(other)["check_reason"], "only a contract_incomplete hold says why the contract is incomplete"

    ActiveRecord::Base.transaction { Leverage::Holds.close(scenario.context, hold: hold, task: task) }
    assert_nil card(task)["check_reason"]
  end

  test "a contract_incomplete hold that names no check has no reason" do
    task = scenario.task(state: "backlog")
    scenario.hold(task, reason: "contract_incomplete", item: false)

    assert_nil card(task)["check_reason"]
  end

  test "the card says checking exactly when the task page names a waiting command and no hold is open: one reading" do
    waiting, = checking_task
    held, = checking_task
    scenario.hold(held, reason: "owner_hold", item: false)
    quiet = scenario.task(state: "ready")

    [ waiting, held, quiet ].each do |task|
      page = page(task)
      open_hold = page["holds"].any? { |hold| hold["closed_at"].nil? }
      assert_equal !page["pending"].nil? && !open_hold, card(task)["checking"], task.id
    end
  end

  test "another workspace's transitions never make a card checking" do
    task = scenario.task(state: "backlog")
    elsewhere = Scenario.new
    foreign = elsewhere.task(state: "backlog")
    elsewhere.pending_transition(foreign, command: "complete_contract", requester: elsewhere.owner)

    assert_equal false, card(task)["checking"]
  end

  test "a Finishing card waits for the builder exactly when an action is approved and the task has no holder" do
    actions = [ { kind: "publish", description: "Publish the sample.", state: "approved" } ]
    waiting = scenario.finishing_task(holder: false, actions: actions)
    held = scenario.finishing_task(actions: actions)
    requested = scenario.finishing_task(actions: [ actions.first.merge(state: "requested") ])
    ready = scenario.task(state: "ready")

    assert_equal true, card(waiting)["waits_for_builder"]
    [ held, requested, ready ].each do |task|
      assert_equal false, card(task)["waits_for_builder"], task.id
    end
  end

  test "the board and task page flag only the review with no independent General seat" do
    first = scenario.seat(role: "general", provider: "claude")
    second = scenario.seat(role: "general", provider: "codex")
    blocked = scenario.task(state: "in_review", builder: first)
    scenario.append("task.claimed", task: blocked, actor_kind: "seat", actor_id: second.id,
      payload: { seat_id: second.id, credential_id: nil, model: second.model })
    reviewable = scenario.task(state: "in_review", builder: first)

    assert_equal true, board["reviewer_seat_exists"], "the workspace has reviewer seats"
    assert_equal false, card(blocked)["reviewer_seat_exists"]
    assert_equal false, page(blocked)["reviewer_seat_exists"]
    assert_equal true, card(reviewable)["reviewer_seat_exists"]
    assert_equal true, page(reviewable)["reviewer_seat_exists"]
  end

  test "a General-only Ready task names the limited login it waits for" do
    limited = scenario.credential
    scenario.seat(role: "general", credential: limited)
    reset = scenario.database_now.change(usec: 0) + 1.hour
    scenario.limit_credential(limited, reset_at: reset)
    task = scenario.task(state: "ready")
    scenario.append("task.released", task: task, payload: { reason: "unable_to_continue", wait_cause: "credential_limit" })

    assert_equal [ limited.id, reset ], account_wait(card(task))
    assert_equal [ limited.id, reset ], account_wait(page(task))
  end

  test "a General seat that reviewed a Ready task does not hide the builder's limited login" do
    free = scenario.credential(provider: "codex", position: 1)
    limited = scenario.credential(provider: "claude", position: 2)
    reviewer = scenario.seat(role: "general", credential: free)
    builder = scenario.seat(role: "builder", credential: limited)
    reset = scenario.database_now.change(usec: 0) + 1.hour
    scenario.limit_credential(limited, reset_at: reset)
    task = ready_after_failed_review(builder, reviewer)

    assert_equal "credential_limit", TaskStep.find_by!(task_id: task.id, kind: "wait_ready", closed_at: nil).cause_kind
    expected = [ limited.id, reset ]
    assert_equal [ expected, expected ], [ account_wait(card(task)), account_wait(page(task)) ]
  end

  test "Ready account waits on the board reflect each task's General review history" do
    free = scenario.credential(provider: "codex", position: 1)
    signed_out = scenario.credential(provider: "claude", position: 2)
    reviewer = scenario.seat(role: "general", credential: free)
    builder = scenario.seat(role: "builder", credential: signed_out)
    scenario.sign_out_credential(signed_out)
    first = scenario.task(state: "ready")
    reviewed = ready_after_failed_review(builder, reviewer)
    last = scenario.task(state: "ready")

    cards = board.fetch("tasks")
    assert_equal [ first.id, reviewed.id, last.id ], cards.map { |entry| entry.dig("task", "id") }
    expected = [ [ nil, nil ], [ signed_out.id, nil ], [ nil, nil ] ]
    assert_equal expected, cards.map { |entry| account_wait(entry) }
    assert_equal expected, [ first, reviewed, last ].map { |task| account_wait(page(task)) }
  end

  test "an eligible General seat that connects on its own removes a mixed workspace account wait" do
    limited = scenario.credential
    scenario.seat(role: "reviewer", credential: limited)
    scenario.limit_credential(limited, reset_at: scenario.database_now + 1.hour)
    scenario.seat(role: "general", provider: "codex")
    task = scenario.task(state: "in_review")

    assert_nil card(task)["waiting_for_credential_id"]
    assert_nil page(task)["waiting_for_credential_id"]
  end

  test "a General seat barred by the provider rule does not hide an eligible reviewer's login wait" do
    scenario.with_shipped_rules
    builder = scenario.seat(role: "builder", provider: "claude")
    login = scenario.credential(provider: "codex")
    scenario.seat(role: "reviewer", credential: login)
    scenario.seat(role: "general", provider: "claude")
    reset = scenario.database_now.change(usec: 0) + 1.hour
    scenario.limit_credential(login, reset_at: reset)
    task = scenario.task(state: "in_review", builder: builder)

    assert_equal true, card(task)["reviewer_seat_exists"]
    assert_equal [ login.id, reset ], account_wait(card(task))
    assert_equal [ login.id, reset ], account_wait(page(task))
  end

  test "a General builder cannot hide another General reviewer's limited login" do
    builder = scenario.seat(role: "general")
    limited = scenario.credential(provider: "codex")
    scenario.seat(role: "general", credential: limited)
    reset = scenario.database_now.change(usec: 0) + 1.hour
    scenario.limit_credential(limited, reset_at: reset)
    task = scenario.task(state: "in_review", builder: builder)

    assert_equal [ limited.id, reset ], account_wait(card(task))
    assert_equal [ limited.id, reset ], account_wait(page(task))
  end

  test "a General seat's signed-out Gemini login cannot become a review account wait" do
    gemini = scenario.credential(provider: "gemini")
    scenario.seat(role: "general", credential: gemini)
    gemini.update_columns(state: "signed_out")
    task = scenario.task(state: "in_review")

    assert_nil card(task)["waiting_for_credential_id"]
    assert_nil page(task)["waiting_for_credential_id"]
    assert_equal false, page(task)["reviewer_seat_exists"]
  end

  test "a General run on Gemini cannot review while a later login is available" do
    gemini = scenario.credential(provider: "gemini", position: 1)
    scenario.credential(provider: "codex", position: 2)
    scenario.seat(role: "general", credential: gemini)
    task = scenario.task(state: "in_review")

    assert_equal false, card(task)["reviewer_seat_exists"]
    assert_equal false, page(task)["reviewer_seat_exists"]
    assert_nil card(task)["waiting_for_credential_id"]
  end

  def account_wait(read)
    [ read.fetch("waiting_for_credential_id"), read["waiting_until"] && Time.iso8601(read["waiting_until"]) ]
  end

  test "a card waits for a stronger agent when the task is Ready and has a minimum strength rank" do
    ready = scenario.task(state: "ready")
    escalated = scenario.task(state: "ready")
    working = scenario.task(state: "working")
    [ escalated, working ].each { |task| task.update_columns(minimum_strength_rank: 2) }

    assert_equal true, card(escalated)["waits_for_stronger_agent"]
    assert_equal false, card(ready)["waits_for_stronger_agent"]
    assert_equal false, card(working)["waits_for_stronger_agent"]
  end

  private

  def ready_after_failed_review(builder, reviewer)
    task = scenario.task(state: "in_review", builder: builder)
    review = scenario.review(task, reviewer: reviewer)
    hash = Leverage::Briefing.hash_for(task, seat: reviewer, review: review)
    assert_completed(seat_command(reviewer, "acknowledge_review_briefing", { "id" => review.id, "briefing_hash" => hash }))
    criterion = Criterion.find_by!(task_id: task.id, kind: "build")
    assert_completed(seat_command(reviewer, "fail_review", { "id" => review.id, "verdict" => "failed",
      "failed_criteria" => [ criterion.id ], "notes" => "", "tokens" => 0, "spend" => 0 }))
    assert_equal "ready", task.reload.state
    task
  end
end
