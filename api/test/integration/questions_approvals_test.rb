require "test_helper"
require_relative "../support/http_calls"

# Milestone 5 plan WP13 and §5.2: the owner, helper and seats use the HTTP
# interfaces. Scenario supplies only the workspace, its callers and rules.
class QuestionsApprovalsHttpTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  PUBLISH = { "kind" => "publish", "description" => "Publish the sample page." }.freeze
  SEND = { "kind" => "send", "description" => "Send the sample review note." }.freeze
  APPROVAL = { "decision" => "approve", "reason" => "The contract names this action." }.freeze
  QUESTION = { "text" => "Which sample should I use?", "assumption" => "Use the first sample.", "blocking" => true }.freeze
  CONTRACT = {
    "title" => "Prepare the sample page", "goal" => "Use the reviewed sample data.", "details" => "Use the figures in the sample brief.",
    "criteria" => [ { "kind" => "build", "text" => "The sample page matches the brief." },
                    { "kind" => "review", "text" => "An independent reviewer agrees." } ],
    "work_reference" => "~/work/sample-page", "minimum_strength_rank" => nil, "budget_cap" => nil
  }.freeze

  setup do
    @scenario = Scenario.new(lease_length_seconds: 600)
    @owner = @scenario.owner_token
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential(provider: "claude"))
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
    @orchestrator = @scenario.orchestrator
  end

  test "a form action survives both contract requests and reaches Done after review and approval" do
    approval_rule
    task_id = add_task([ PUBLISH ])
    action = task_page(task_id).fetch("actions").sole
    action_id = action.fetch("id")
    complete_contract(task_id, [ PUBLISH ])
    assert_equal [ [ action_id, 1, "publish", "contracted" ] ], action_rows(task_id)

    claim_task(task_id)
    submit_task(task_id)
    review_id = start_review(task_id)

    before = last_seq
    refused("approve_action", @owner, "invalid_state", ids: { "id" => action_id })
    assert_equal before, last_seq
    page = task_page(task_id)
    assert_equal "in_review", page.dig("task", "state")
    assert_equal "contracted", page.fetch("actions").sole.fetch("state")

    pass_review(review_id)
    approve_job
    assert_equal [ "action", task_id ], next_item(@builder)
    acknowledge_task(task_id)
    perform_action(task_id, action_id)

    page = task_page(task_id)
    assert_equal [ "done", nil ], page.fetch("task").values_at("state", "holder_seat_id")
    assert_equal [ action_id, "done" ], page.fetch("actions").sole.values_at("id", "state")
    types = %w[review.passed action.requested check.queued job.queued job.claimed job.finished check.finished
               action.approved action.started action.reported_done task.done]
    assert_equal types, page.fetch("events").pluck("type").select { |type| types.include?(type) }
    approved = page.fetch("events").find { |event| event.fetch("type") == "action.approved" }
    assert_equal [ "seat", @orchestrator.id, action_id, @builder.id ],
      approved.values_at("actor_kind", "actor_id", "subject_id") + [ approved.dig("payload", "lease_seat_id") ]
    assert_equal [ "approval", action_id, false ], decisions.sole.values_at("kind", "action_id", "undoable")

    completed("overturn_approval", @owner, ids: { "id" => action_id })
    assert_equal [ "recorded_only", "done" ], decisions.sole.values_at("overturn_effect", "action_state")
    assert_equal "done", task_page(task_id).dig("task", "state")
  end

  test "an expired Finishing lease opens Unconfirmed action and a second builder cannot claim" do
    task_id, action_id = approved_action
    acknowledge_task(task_id)
    completed("start_action", token(@builder), ids: { "id" => task_id, "aid" => action_id })
    expire_and_refuse_second_builder(task_id, action_id, announced: true)
  end

  test "a run reported stopped leaves the approved action and its lease until expiry" do
    task_id, action_id = approved_action
    before = last_seq
    lease = task_page(task_id).fetch("task").values_at("holder_seat_id", "lease_due_at")
    assert_equal @builder.id, lease.first
    assert lease.last
    builder_token = token(@builder)
    completed("report_run_stopped", @scenario.helper_token, ids: { "id" => @builder.id },
      body: { "credential_id" => @builder.credential_id, "observed_at" => @scenario.database_now.utc.iso8601(6),
              "stop_reason" => "stopped" })

    assert_equal before, last_seq
    page = task_page(task_id)
    assert_equal lease, page.fetch("task").values_at("holder_seat_id", "lease_due_at")
    assert_equal "approved", page.fetch("actions").sole.fetch("state")
    assert_empty inbox.pluck("kind")
    exchange("get_next", builder_token, status: 401, query: { "wait" => 0 })

    expire_and_refuse_second_builder(task_id, action_id, announced: false)
  end

  test "the before anything goes out gate runs before approval of its action while another action can be approved" do
    approval_rule
    completed("add_rule", @owner, body: {
      "name" => "Check sample prices", "instruction" => "Check the prices against the sample brief.",
      "hook" => "action.requested", "scope" => { "kind" => "action_kinds", "project_ids" => nil, "action_kinds" => [ "publish" ] }
    })
    task_id = add_task([ PUBLISH, SEND ])
    publish_id, send_id = task_page(task_id).fetch("actions").pluck("id")
    complete_contract(task_id, [ PUBLISH, SEND ])
    assert_equal [ [ publish_id, 1, "publish", "contracted" ], [ send_id, 2, "send", "contracted" ] ], action_rows(task_id)
    claim_task(task_id)
    submit_task(task_id)

    # Trace 04's builder has another task when the approvals finish.
    other_id = add_task([])
    complete_contract(other_id, [])
    claim_task(other_id)
    pass_review(start_review(task_id))
    assert_equal %w[requested requested], task_page(task_id).fetch("actions").pluck("state")

    gate = claim_job("rule_check")
    finish_job(gate, { "result" => "passed", "reason" => "The sample prices match." })
    approve_job
    page = task_page(task_id)
    assert_equal %w[requested approved], page.fetch("actions").pluck("state")
    assert_nil page.dig("task", "holder_seat_id")
    approve_job
    page = task_page(task_id)
    assert_equal %w[approved approved], page.fetch("actions").pluck("state")
    assert_nil page.dig("task", "holder_seat_id")

    submit_task(other_id)
    assert_equal [ "action", task_id ], next_item(@builder)
    acknowledge_task(task_id)
    perform_action(task_id, publish_id)
    assert_equal "finishing", task_page(task_id).dig("task", "state")
    perform_action(task_id, send_id)

    page = task_page(task_id)
    assert_equal "done", page.dig("task", "state")
    approvals = page.fetch("events").select { |event| event.fetch("type") == "action.approved" }
    assert_equal [ send_id, publish_id ], approvals.pluck("subject_id")
    checks = page.fetch("events").select do |event|
      event.fetch("type") == "check.finished" && event.dig("payload", "hook") == "action.requested"
    end
    assert_equal [ [ send_id, "not_applicable" ], [ publish_id, "passed" ], [ send_id, "applied" ], [ publish_id, "applied" ] ],
      checks.map { |event| event.fetch("payload").values_at("subject_id", "result") }
    assert_equal [ publish_id, send_id ],
      page.fetch("events").select { |event| event.fetch("type") == "action.reported_done" }.pluck("subject_id")
  end

  test "Needs you shows a stopped approval reason outside the event log and item facts" do
    approval_rule
    task_id, action_id = action_in_review
    pass_review(start_review(task_id))
    reason = "The sample audience is wider than the contract allows."
    finish_job(claim_job("approval"), { "decision" => "stop", "reason" => reason })

    item = inbox.sole
    assert_equal [ "stopped_action", task_id ], item.values_at("kind", "about_id")
    assert_equal action_id, item.dig("facts", "action_id")
    assert item["detail"] == reason, "Needs you did not show the approval reason"
    refute JSON.generate(item.fetch("facts")).include?(reason), "the approval reason reached item facts"
    refute JSON.generate(task_page(task_id).fetch("events")).include?(reason), "the approval reason reached the event log"

    # The inbox can read this item while a later command resolves it. Its
    # detail must never come from another decision about the same action.
    old_item = InboxItem.find(item.fetch("id"))
    completed("return_for_rework", @owner, ids: { "id" => task_id },
      body: { "criterion_ids" => [ criterion_ids(task_id).fetch("cid") ] })
    acknowledge_task(task_id)
    submit_task(task_id)
    pass_review(start_review(task_id))
    new_reason = "The new sample needs another review."
    finish_job(claim_job("approval"), { "decision" => "stop", "reason" => new_reason })
    assert inbox.sole["detail"] == new_reason, "Needs you did not show the later decision's reason"
    earlier = Leverage::Reads::Inbox.shapes(@scenario.workspace_id, [ [ old_item, item.fetch("opened_seq") ] ]).sole
    refute earlier.key?(:detail), "a resolved item picked up the later decision's reason"
  end

  test "an orchestrator decision surfaces until read and a read after submit is refused" do
    task_id, question_id = ask_blocking_question
    answer = "Use the second sample."
    job = claim_job("question")
    oversized = { "outcome" => "answered", "answer" => "a" * 4001, "basis" => "decision" }
    exchange("submit_job_result", token(@orchestrator), status: 422, key: new_key, ids: { "id" => job },
      body: { "result" => oversized, "tokens" => 0, "spend" => 0 }, check_request: false)
    assert_equal "claimed", Job.find(job).state
    finish_job(job, { "outcome" => "answered", "answer" => answer, "basis" => "decision" })

    assert_empty inbox.pluck("kind")
    page = task_page(task_id)
    assert_empty page.fetch("holds")
    refute_includes page.fetch("steps").pluck("kind"), "wait_owner"
    assert_question_events(page, %w[question.asked check.finished job.queued job.claimed job.finished question.answered])
    routing = page.fetch("events").find { |event| event.fetch("type") == "check.finished" }
    assert_equal [ "applied", "to_orchestrator" ], routing.fetch("payload").values_at("result", "effect")
    assert_equal [ "question", question_id, true ], decisions.sole.values_at("kind", "question_id", "undoable")
    assert_equal [ "answer", question_id ], next_item(@builder)
    assert_nil Question.find(question_id).read_at
    assert_question_answer(task_id, question_id, answer, "decision")
    assert Question.find(question_id).read_at, "a holder's GET did not mark the answer read"
    assert_equal [ "none", nil ], next_item(@builder)

    submit_task(task_id)
    exchange("get_question", token(@builder), status: 409, ids: { "id" => task_id, "qid" => question_id })
    assert_equal "not_holder", response.parsed_body.fetch("code")
    pass_review(start_review(task_id))
    assert_equal "done", task_page(task_id).dig("task", "state")
  end

  test "a passed-on blocking question holds the builder until the owner answers" do
    task_id, question_id = ask_blocking_question
    finish_job(claim_job("question"), { "outcome" => "passed_on", "answer" => nil, "basis" => nil })

    item = inbox.sole
    assert_equal [ "question_passed_on", task_id, [ "answer" ] ], item.values_at("kind", "about_id", "choices")
    assert_equal question_id, item.dig("facts", "question_id")
    hold = task_page(task_id).fetch("holds").sole
    assert_equal [ "owner_question", nil ], hold.values_at("reason", "closed_at")
    refused("pass_criterion", token(@builder), "on_hold", ids: criterion_ids(task_id), body: evidence)

    answer = QUESTION.fetch("assumption")
    completed("answer_question", @owner, ids: { "id" => question_id }, body: { "answer" => answer })
    assert_empty inbox.pluck("kind")
    assert_empty decisions.pluck("kind")
    assert_equal [ "resume", task_id ], next_item(@builder)
    acknowledge_task(task_id)
    assert_equal [ "answer", question_id ], next_item(@builder)
    assert_question_answer(task_id, question_id, answer, "owner")
    assert_equal [ "none", nil ], next_item(@builder)

    submit_task(task_id)
    pass_review(start_review(task_id))
    page = task_page(task_id)
    assert_equal "done", page.dig("task", "state")
    assert_question_events(page, %w[question.asked check.finished job.queued job.claimed job.finished
                                    hold.opened inbox.opened question.answered hold.closed inbox.resolved])
    assert_owner_wait(page, hold.fetch("id"))
  end

  private

  def token(seat) = @scenario.token_for(seat)
  def last_seq = @scenario.workspace.reload.last_seq
  def approval_rule = @scenario.rule(key: "orchestrator_approves_actions", origin: "shipped")

  def exchange(operation, bearer, status: 200, **options)
    call(operation, token: bearer, **options)
    assert_equal status, response.status, operation
    assert_response_matches_contract
    response.parsed_body
  end

  # Keep task content and authentication material out of failed schema assertions.
  def assert_valid(pointer, body, what)
    errors = openapi_schemer.ref(pointer).validate(body).map { |error| error.values_at("data_pointer", "type") }
    assert_empty errors, "#{what} does not match the contract (#{pointer})"
  end

  def completed(operation, bearer, **options)
    body = exchange(operation, bearer, key: new_key, **options)
    assert_equal "completed", body.fetch("outcome"), operation
    body.fetch("result")
  end

  def refused(operation, bearer, code, **options)
    body = exchange(operation, bearer, status: 409, key: new_key, **options)
    assert_equal code, body.dig("refusal", "code"), operation
  end

  def task_page(task_id) = exchange("get_task", @owner, ids: { "id" => task_id })
  def inbox = exchange("list_inbox", @owner).fetch("items")
  def decisions = exchange("list_decisions", @owner).fetch("decisions")

  def next_item(seat)
    exchange("get_next", token(seat), query: { "wait" => 0 }).values_at("kind", "id")
  end

  def add_task(actions)
    body = CONTRACT.slice("title", "goal", "work_reference").merge("state" => "backlog", "priority" => "normal", "actions" => actions)
    completed("add_task", @owner, body: body).fetch("task_id")
  end

  def complete_contract(task_id, actions)
    completed("complete_contract", @owner, ids: { "id" => task_id }, body: CONTRACT.merge("actions" => actions))
  end

  def action_rows(task_id)
    task_page(task_id).fetch("actions").map { |action| action.values_at("id", "position", "kind", "state") }
  end

  def claim_task(task_id)
    claimed = completed("claim_next_task", token(@builder))
    assert_equal task_id, claimed.dig("task", "id")
    acknowledge_task(task_id)
  end

  def acknowledge_task(task_id)
    acknowledge(task_id, @builder, "task")
  end

  def acknowledge(id, seat, kind)
    ids = { "id" => id }
    briefing = exchange("get_#{kind}_briefing", token(seat), ids: ids).fetch("briefing")
    completed("acknowledge_#{kind}_briefing", token(seat), ids: ids, body: { "briefing_hash" => briefing.fetch("hash") })
  end

  def criterion_ids(task_id)
    criterion = task_page(task_id).fetch("criteria").find { |row| row.fetch("kind") == "build" }
    { "id" => task_id, "cid" => criterion.fetch("id") }
  end

  def evidence
    { "evidence" => { "kind" => "link", "value" => "https://example.test/sample-page" } }
  end

  def submit_task(task_id)
    ids = criterion_ids(task_id)
    completed("start_criterion", token(@builder), ids: ids)
    completed("pass_criterion", token(@builder), ids: ids, body: evidence)
    completed("submit_task", token(@builder), ids: { "id" => task_id },
      body: { "handoff_note" => "Checked the sample figures.", "work_reference" => nil })
  end

  def start_review(task_id)
    review = completed("claim_next_review", token(@reviewer)).fetch("review")
    assert_equal task_id, review.fetch("task_id")
    id = review.fetch("id")
    acknowledge(id, @reviewer, "review")
    id
  end

  def pass_review(review_id)
    next_item(@orchestrator)
    completed("give_verdict", token(@reviewer), ids: { "id" => review_id },
      body: { "verdict" => "passed", "failed_criteria" => [], "notes" => "The sample meets the contract.", "tokens" => 10, "spend" => 0 })
  end

  def claim_job(kind)
    assert_equal [ "job", nil ], next_item(@orchestrator)
    job = completed("claim_next_job", token(@orchestrator))
    assert_equal kind, job.fetch("kind")
    job.fetch("job_id")
  end

  def finish_job(job_id, result)
    completed("submit_job_result", token(@orchestrator), ids: { "id" => job_id },
      body: { "result" => result, "tokens" => 10, "spend" => 0 })
  end

  def approve_job
    finish_job(claim_job("approval"), APPROVAL)
  end

  def perform_action(task_id, action_id)
    ids = { "id" => task_id, "aid" => action_id }
    completed("start_action", token(@builder), ids: ids)
    completed("report_action_done", token(@builder), ids: ids)
  end

  def action_in_review
    task_id = add_task([ PUBLISH ])
    complete_contract(task_id, [ PUBLISH ])
    action_id = task_page(task_id).fetch("actions").sole.fetch("id")
    claim_task(task_id)
    submit_task(task_id)
    [ task_id, action_id ]
  end

  def approved_action
    approval_rule
    task_id, action_id = action_in_review
    pass_review(start_review(task_id))
    approve_job
    assert_equal [ "action", task_id ], next_item(@builder)
    [ task_id, action_id ]
  end

  def expire_and_refuse_second_builder(task_id, action_id, announced:)
    other = @scenario.seat(role: "builder")
    before = last_seq
    @scenario.make_due(Task.find(task_id))
    refused("claim_next_task", token(other), "not_eligible")

    page = task_page(task_id)
    assert_equal [ "finishing", @builder.id, nil, nil ],
      page.fetch("task").values_at("state", "builder_seat_id", "holder_seat_id", "lease_due_at")
    assert_equal [ "action_unconfirmed", nil ], page.fetch("holds").sole.values_at("reason", "closed_at")
    expired = page.fetch("events").select { |event| event.fetch("seq") > before }
    assert_equal %w[task.lease_expired hold.opened inbox.opened], expired.pluck("type")
    assert_nil expired.first.fetch("command_id")
    item = inbox.sole
    assert_equal [ "unconfirmed_action", task_id ], item.values_at("kind", "about_id")
    assert_equal [ [ action_id ], announced ], item.fetch("facts").values_at("action_ids", "builder_announced_start")
  end

  def ask_blocking_question
    @scenario.rule(key: "ask_orchestrator_first", origin: "shipped")
    task_id = add_task([])
    complete_contract(task_id, [])
    claim_task(task_id)
    asked = completed("ask_question", token(@builder), ids: { "id" => task_id }, body: QUESTION)
    [ task_id, asked.fetch("question_id") ]
  end

  def assert_question_answer(task_id, question_id, answer, basis)
    body = exchange("get_question", token(@builder), ids: { "id" => task_id, "qid" => question_id })
    assert_equal [ question_id, "answered", basis ], body.values_at("id", "outcome", "basis")
    assert body.fetch("answer") == answer, "GET returned a different answer"
  end

  def assert_question_events(page, expected)
    actual = page.fetch("events").pluck("type").select { |type| expected.include?(type) }
    assert_equal expected, actual
  end

  def assert_owner_wait(page, hold_id)
    steps = page.fetch("steps")
    wait = steps.select { |step| step.fetch("kind") == "wait_owner" }.sole
    assert_equal [ "hold", hold_id ], wait.values_at("subject_kind", "subject_id")
    index = steps.index(wait)
    assert_operator index, :>, 0
    assert_equal %w[build wait_owner build], steps.slice(index - 1, 3).pluck("kind")
    steps.each_cons(2) do |previous, following|
      assert_equal previous.fetch("closed_at"), following.fetch("opened_at")
    end
    assert_in_delta page.fetch("lifetime_seconds"), steps.sum { |step| step.fetch("seconds") }, 0.000_001
  end
end
