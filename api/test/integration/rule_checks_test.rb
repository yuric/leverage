require "test_helper"
require_relative "../support/http_calls"
require_relative "../support/integration_helpers"

# Rule checks over HTTP (PRD L875 Rule checks; release lines L907, L910,
# L912, L913, L919; milestone 4 plan WP13, RD-12, RD-37, RE-3, §2.1 rule
# 11), through the three interfaces with the real entries and the real
# rules engine behind them:
#
# - L907: with the acceptance-criteria rule on, no call moves a task
#   without a build criterion into Ready, the owner's Complete contract
#   or a planner's draft (RE-6); with it off, the same call does.
# - RD-37: a planner's draft cannot change where the work is, its minimum
#   strength rank or its budget cap.
# - A rule change answers briefing_changed to the builder's next work call
#   and to GET /v1/next (L476).
# - Traces 16 to 19 sent whole (RuleTraceHttpRunner), each compared event
#   for event and step for step, then replayed and audited; and between
#   their commands what a client reads: the override's who, when and why
#   and the resend that completes (L910); review claim-next writing the
#   provider rule's applied row and the step's cause while GET /v1/next
#   never answers review for that review (RD-12, L912); a reviewer's limit
#   that passes over a provider that built the task and releases the
#   review (L913); and for each ending of rule 11 that the traces reach,
#   the requester's GET /v1/next answering command and GET
#   /v1/commands/{key} its refusal: task_cancelled (L919), lease_expired
#   and invalid_state.
class RuleChecksTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls
  include IntegrationHelpers

  CONTRACT = { "title" => "A made-up task", "goal" => "A made-up goal.", "details" => "Made-up details.",
               "criteria" => [ { "text" => "Made-up build criterion.", "kind" => "build" },
                               { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
               "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil,
               "work_reference" => "~/work/made-up" }.freeze
  # A contract with no build criterion: the acceptance-criteria rule's
  # minimum is one (shipped_rules.json).
  NO_BUILD = CONTRACT.merge("criteria" => [ { "text" => "An independent reviewer agrees.", "kind" => "review" } ]).freeze

  def owner = @scenario.owner_token

  def token(seat) = @scenario.token_for(seat)

  def rule(key) = Rule.find_by!(workspace_id: @scenario.workspace_id, key: key)

  def owner_post(operation_id, ids: {}, body: nil, status: :ok)
    call(operation_id, token: owner, key: new_key(operation_id.tr("_", "-")), ids: ids, body: body)
    assert_response status, "#{operation_id}: #{response.body}"
    assert_response_matches_contract
    response.parsed_body
  end

  def get_task(task)
    call("get_task", token: owner, ids: { "id" => task.id })
    assert_response :ok
    assert_response_matches_contract
    response.parsed_body
  end

  def turn_off(key) = owner_post("disable_rule", ids: { "id" => rule(key).id })

  def contract_incomplete?(task)
    Hold.exists?(task_id: task.id, reason: "contract_incomplete", closed_at: nil)
  end

  # --- L907 --------------------------------------------------------------------

  # "Every task needs specific details" is a model rule at the same moment:
  # it is turned off first, so that what the owner sees is the acceptance
  # rule's alone.
  test "L907: with the acceptance-criteria rule on the owner's contract with no build criterion stays in Backlog; off, it is Ready" do
    @scenario = Scenario.new
    @scenario.with_shipped_rules
    task = @scenario.task(state: "backlog")
    setup = @scenario.workspace.reload.last_seq
    turn_off("specific_details")

    answer = owner_post("complete_contract", ids: { "id" => task.id }, body: NO_BUILD)
    assert_equal "completed", answer.fetch("outcome"), "the contract change is kept (RD-10)"
    assert_equal "backlog", task.reload.state
    assert contract_incomplete?(task)
    page = get_task(task)
    check = page.fetch("rule_checks").sole
    assert_equal [ rule("acceptance_criteria").id, "failed", "task.before_ready" ], check.values_at("rule_id", "result", "hook")
    assert_match(/criteri/, check.fetch("reason"))
    assert_equal [ "contract_incomplete" ], page.fetch("holds").select { |hold| hold.fetch("closed_at").nil? }.map { |hold| hold.fetch("reason") }

    turn_off("acceptance_criteria")
    answer = owner_post("complete_contract", ids: { "id" => task.id }, body: NO_BUILD)
    assert_equal "completed", answer.fetch("outcome")
    assert_equal "ready", task.reload.state
    refute contract_incomplete?(task)
    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: setup)
  end

  test "L907: with the acceptance-criteria rule on a planner's draft with no build criterion stays in Backlog; off, it is Ready" do
    @scenario = Scenario.new
    @scenario.with_shipped_rules
    planner = @scenario.planner(credential: @scenario.credential(provider: "claude"))
    first, second = Array.new(2) { @scenario.task(state: "backlog") }
    setup = @scenario.workspace.reload.last_seq
    turn_off("specific_details")

    held = draft_through(planner, NO_BUILD, task: first)
    assert_equal "completed", held.fetch(:answer).fetch("outcome"), "the result is taken; its contract waits for nothing"
    assert_equal "backlog", held.fetch(:task).reload.state
    assert contract_incomplete?(held.fetch(:task))
    assert_equal "failed", RuleCheck.find_by!(task_id: held.fetch(:task).id).result

    turn_off("acceptance_criteria")
    ready = draft_through(planner, NO_BUILD, task: second)
    assert_equal "completed", ready.fetch(:answer).fetch("outcome")
    assert_equal "ready", ready.fetch(:task).reload.state
    assert_empty RuleCheck.where(task_id: ready.fetch(:task).id)
    assert_empty Leverage::Replay.diff(@scenario.workspace_id)
    assert_empty Leverage::LogAudit.call(@scenario.workspace_id, after_seq: setup)
  end

  # --- RD-37 -------------------------------------------------------------------

  test "RD-37: a planner's draft that names another work reference, rank and cap leaves the task's own" do
    @scenario = Scenario.new
    @scenario.with_shipped_rules
    assert_equal 7, turn_shipped_rules_off(owner).size
    assert_empty turn_shipped_rules_off(owner), "a second call turns nothing off"
    planner = @scenario.planner(credential: @scenario.credential(provider: "claude"))
    task = @scenario.task(state: "backlog")
    task.update_columns(work_reference: "~/work/the-site", minimum_strength_rank: nil, budget_cap: nil)

    other = CONTRACT.merge("work_reference" => "~/somewhere/else", "minimum_strength_rank" => 3, "budget_cap" => 99.5)
    done = draft_through(planner, other, task: task)
    assert_equal "completed", done.fetch(:answer).fetch("outcome")
    task.reload
    assert_equal [ "ready", "~/work/the-site", nil, nil ],
      [ task.state, task.work_reference, task.minimum_strength_rank, task.budget_cap ]
    assert_equal CONTRACT.fetch("goal"), task.goal
  end

  # --- briefing_changed ----------------------------------------------------------

  test "a rule change answers briefing_changed to the builder's next work call and to GET /v1/next" do
    @scenario = Scenario.new
    @scenario.with_shipped_rules
    builder = @scenario.seat(role: "builder", credential: @scenario.credential(provider: "claude"))
    task = @scenario.task(state: "working", builder: builder)
    criterion = Criterion.where(task_id: task.id, kind: "build").order(:position).first
    read_and_acknowledge(builder, task)

    owner_post("save_rule", ids: { "id" => rule("acceptance_criteria").id },
      body: { "name" => "Every task needs acceptance criteria", "instruction" => nil,
              "parameters" => { "minimum_count" => 2 },
              "scope" => { "kind" => "all_tasks", "project_ids" => [], "action_kinds" => [] }, "on_fail" => "block",
              "route" => "owner", "queue_timeout_seconds" => nil, "run_timeout_seconds" => nil })

    call("get_next", token: token(builder), query: { "wait" => 0 })
    assert_response :ok
    assert_equal [ "briefing_changed", task.id ], response.parsed_body.values_at("kind", "id")
    call("start_criterion", token: token(builder), key: new_key, ids: { "id" => task.id, "cid" => criterion.id })
    assert_response :conflict
    assert_response_matches_contract
    assert_equal "briefing_changed", response.parsed_body.dig("refusal", "code")

    read_and_acknowledge(builder, task)
    call("start_criterion", token: token(builder), key: new_key, ids: { "id" => task.id, "cid" => criterion.id })
    assert_response :ok, response.body
    assert_equal "completed", response.parsed_body.fetch("outcome")
  end

  # --- traces 16 to 19 ---------------------------------------------------------

  test "trace 16 runs over HTTP: a model gate at ready to start, contract_incomplete, a planner's draft that waits" do
    runner = run_trace("16-model-gate-and-draft")
    task = Task.find(runner.bound_id("$task:1"))
    page = get_task_as(runner, task)
    details = rule_of(runner, "specific_details").id
    assert_equal %w[failed passed], page.fetch("rule_checks").select { |row| row.fetch("rule_id") == details }
      .map { |row| row.fetch("result") }, "the model check failed, then passed on the owner's second try"
  end

  test "trace 17 runs over HTTP: a submit refused, let through once and resent (L910), the re-run limit and a warn rule" do
    checked = []
    check = lambda do |index, runner|
      next unless index == 10 # the override of the failed check

      override = Leverage::Contract.trace(runner.name).dig("commands", 10)
      row = RuleCheck.find(runner.bound_id(override.dig("path_params", "id")))
      page = get_task_as(runner, Task.find(row.task_id))
      shown = page.fetch("rule_checks").find { |item| item.fetch("id") == row.id }
      assert_equal [ runner.scenario.owner.id, override.dig("body", "reason") ],
        shown.values_at("overridden_by_user_id", "override_reason"), "L910: who and why"
      refute_nil shown.fetch("overridden_at"), "L910: when"
      checked << :override
    end
    run_trace("17-submit-rule-rerun-and-override", after_command: check)
    assert_equal [ :override ], checked
  end

  # Rule 11's endings the trace reaches, by the index (0-based) of the
  # command that ends the waiting command and the index of that waiting
  # command: the code its requester reads.
  ENDINGS_18 = { 10 => [ 9, "invalid_state" ], 35 => [ 33, "lease_expired" ], 45 => [ 43, "lease_expired" ],
                 50 => [ 49, "task_cancelled" ] }.freeze

  test "trace 18 runs over HTTP: the claim gate, the done gate, and each ending's code read by its requester (rule 11, L919)" do
    seen = []
    check = lambda do |index, runner|
      next unless ENDINGS_18.key?(index)

      waiting, code = ENDINGS_18.fetch(index)
      seen << told(runner, waiting, code)
    end
    run_trace("18-claim-gate-done-gate-and-ends", after_command: check)
    assert_equal ENDINGS_18.values, seen
  end

  test "trace 19 runs over HTTP: the provider rule's skips and no review offered (RD-12, L912), L913, offline and back" do
    seen = []
    check = lambda do |index, runner|
      case index
      when 14, 15 then seen << skipped_review(runner, index)
      when 36 then seen << released_on_limit(runner)
      end
    end
    # GET /v1/next answers nothing to the two reviewers the rule refuses,
    # just before each claims (RD-12).
    run_trace("19-provider-rule-offline-and-jobs", next_before: { 14 => "none", 15 => "none" }, after_command: check)
    assert_equal [ :skipped, :skipped, :released ], seen
  end

  private

  def run_trace(name, next_before: {}, after_command: nil)
    runner = RuleTraceHttpRunner.new(self, name, next_before: next_before, after_command: after_command).run
    assert_empty runner.failures, runner.failures.first(20).join("\n")
    assert_empty Leverage::Replay.diff(runner.workspace_id), "the replay of the log"
    assert_empty Leverage::LogAudit.call(runner.workspace_id, after_seq: runner.audit_from),
      "the log audit, the setup built over HTTP included"
    runner
  end

  def get_task_as(runner, task)
    call("get_task", token: runner.owner_token, ids: { "id" => task.id })
    assert_response :ok
    assert_response_matches_contract
    response.parsed_body
  end

  # The requester of the waiting command at index waiting is told: GET
  # /v1/next answers command, and GET /v1/commands/{key} the refusal.
  def told(runner, waiting, code)
    command = Leverage::Contract.trace(runner.name).dig("commands", waiting)
    seat_token = runner.tokens.fetch(command.fetch("caller"))
    key = runner.key_for(command.fetch("key"))
    call("get_next", token: seat_token, query: { "wait" => 0 })
    assert_response :ok
    assert_response_matches_contract
    assert_equal "command", response.parsed_body.fetch("kind"), "#{command.fetch("command")}'s requester is told"
    call("get_command", token: seat_token, ids: { "key" => key })
    assert_response :ok
    assert_response_matches_contract
    [ waiting, response.parsed_body.fetch("outcome") == "refused" && response.parsed_body.dig("refusal", "code") ]
  end

  # After a reviewer's claim-next that the provider rule refused: its
  # applied row with effect refused, over get_task, and the wait_review
  # step's cause the rule (RC-50, RD-11, RD-12).
  def skipped_review(runner, index)
    command = Leverage::Contract.trace(runner.name).dig("commands", index)
    seat = Seat.find(runner.bound_id(command.fetch("caller")))
    task = Task.find_by!(workspace_id: runner.workspace_id, state: "in_review")
    page = get_task_as(runner, task)
    rule_id = rule_of(runner, "different_provider_review").id
    applied = page.fetch("rule_checks").select { |row| row.fetch("hook") == "review.assign" }
    assert(applied.any? { |row| row.values_at("rule_id", "result", "effect") == [ rule_id, "applied", "refused" ] },
      "#{seat.name}: the applied row")
    assert_equal 1, RuleCheck.where(task_id: task.id, hook: "review.assign", subject_id: seat.id).count, "one row per reviewer"
    waiting = page.fetch("steps").select { |step| step.fetch("kind") == "wait_review" && step.fetch("closed_at").nil? }
    assert_equal [ [ "rule", rule_id ] ], waiting.map { |step| step.values_at("cause_kind", "cause_rule_id") }
    :skipped
  end

  # L913: the Codex reviewer's login meets its limit; the only login below
  # is Claude's, a provider that built the task, so the review is released
  # and nobody holds it.
  def released_on_limit(runner)
    task = Task.find_by!(workspace_id: runner.workspace_id, state: "in_review")
    review = Review.where(task_id: task.id).order(:created_at).last
    assert_nil review.reviewer_seat_id, "L913: the review is released, not continued on Claude"
    :released
  end

  def rule_of(runner, key) = Rule.find_by!(workspace_id: runner.workspace_id, key: key)

  # Draft contract over HTTP for task, the planner's claim and its result
  # with contract. Answers the task and the result call's answer.
  def draft_through(planner, contract, task:)
    owner_post("draft_contract", ids: { "id" => task.id })
    call("claim_next_job", token: token(planner), key: new_key("claim-job"))
    assert_response :ok, response.body
    assert_response_matches_contract
    claimed = response.parsed_body.fetch("result")
    assert_equal [ "contract_draft", task.id ], [ claimed.fetch("kind"), claimed.dig("input", "task_id") ]
    call("submit_job_result", token: token(planner), key: new_key("draft-result"), ids: { "id" => claimed.fetch("job_id") },
      body: { "result" => contract, "tokens" => 900, "spend" => 0 })
    assert_includes [ 200, 202 ], response.status, response.body
    assert_response_matches_contract
    { task: task, answer: response.parsed_body }
  end

  def read_and_acknowledge(builder, task)
    call("get_task_briefing", token: token(builder), ids: { "id" => task.id })
    assert_response :ok
    hash = response.parsed_body.dig("briefing", "hash")
    call("acknowledge_task_briefing", token: token(builder), key: new_key("ack"), ids: { "id" => task.id },
      body: { "briefing_hash" => hash })
    assert_response :ok, response.body
  end
end
