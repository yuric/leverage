require "test_helper"
require_relative "../support/http_calls"

# Test 5 (PRD L838, L917; milestone 2 plan IN-8 to IN-11, WP17): every
# served operation that changes something, taken from Http::RouteTable and
# the registry, is sent over HTTP through the real entries and then sent
# again with the same key and the same body. The repeat answers what the
# first call answered (for the five answers that carry a token: the same
# ids with "repeated": true and no token, IN-11) and writes nothing: no
# event, no commands row, no other row. The same key with another body (the
# same fields written out differently: the request hash is over the raw
# bytes, IN-8) is 422 key_reused and writes nothing either.
#
# The one exception is IN-9's: a repeat of sign-out answers 401 and writes
# nothing, because the session that would prove who asks is what the first
# call ended.
#
# Milestone 4 (its plan §1.1, L920, WP13) adds the eleven mutating calls
# it serves and the two reports that name a job, and a command that waits:
# its repeat answers 202 pending, as the first did, and writes nothing.
class IdempotencyHttpTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  T = Leverage::Transitions

  # The exception test 5 names (IN-9).
  SIGN_OUT = "sign_out_owner".freeze

  # The token field of the five answers that carry a token, by operation.
  ONCE = {
    "create_owner" => "session_token", "sign_in_owner" => "session_token", "issue_helper_token" => "helper_token",
    "issue_landing_prompt" => "seat_token", "issue_seat_token" => "seat_token"
  }.freeze

  # Every table a command can write, counted before and after a repeat.
  TABLES = [
    Event, Command, Task, Criterion, Evidence, Review, TaskStep, Hold, BriefingAcknowledgement, Seat, Credential,
    HelperRequest, Helper, Session, User, Workspace, InboxItem, Rule, RuleVersion, RuleCheck, RuleCheckAttempt, Job,
    PendingTransition, Action, Question, Project, BriefEntry, CredentialReading
  ].freeze

  # One call: who sends it and with what. Each case below returns one.
  Call = Data.define(:token, :ids, :body) do
    def initialize(token:, ids: {}, body: nil) = super
  end

  # operation => the method that builds its state and returns its Call.
  CASES = {
    "claim_next_task" => :claim_next_task,
    "acknowledge_task_briefing" => :acknowledge_task_briefing,
    "heartbeat_task" => :heartbeat_task,
    "start_criterion" => :start_criterion,
    "pass_criterion" => :pass_criterion,
    "submit_task" => :submit_task,
    "release_task" => :release_task,
    "claim_next_review" => :claim_next_review,
    "heartbeat_review" => :heartbeat_review,
    "release_review" => :release_review,
    "acknowledge_review_briefing" => :acknowledge_review_briefing,
    "give_verdict" => :give_passed_verdict,
    "create_owner" => :create_owner,
    "sign_in_owner" => :sign_in_owner,
    "add_task" => :add_task,
    "complete_contract" => :complete_contract,
    "cancel_task" => :cancel_task,
    "allow_another_round" => :allow_another_round,
    "connect_seat" => :connect_seat,
    "issue_landing_prompt" => :issue_landing_prompt,
    "start_seat" => :start_seat,
    "stop_seat" => :stop_seat,
    "remove_seat" => :remove_seat,
    "issue_helper_token" => :issue_helper_token,
    "add_credential" => :add_credential,
    "verify_credential" => :verify_credential,
    "install_tool" => :install_tool,
    "report_request_progress" => :report_request_progress,
    "report_request_result" => :report_request_result,
    "issue_seat_token" => :issue_seat_token,
    "report_run_started" => :report_run_started,
    "report_run_stopped" => :report_run_stopped,
    # Milestone 3 (its plan §1.1, test 5 gains every new mutating call).
    "report_limit" => :report_limit,
    "report_signed_out" => :report_signed_out,
    "sign_in_again" => :sign_in_again,
    "promote_task" => :promote_task,
    "edit_contract" => :edit_contract,
    "hold_task" => :hold_task,
    "resume_task" => :resume_task,
    "pause_seat" => :pause_seat,
    "resume_seat" => :resume_seat,
    "change_seat" => :change_seat,
    # Milestone 4 (its plan §2.3, L920).
    "claim_next_job" => :claim_next_job,
    "submit_job_result" => :submit_check_result,
    "add_rule" => :add_rule,
    "save_rule" => :save_rule,
    "enable_rule" => :enable_rule,
    "disable_rule" => :disable_rule,
    "revert_rule" => :revert_rule,
    "remove_rule" => :remove_rule,
    "rerun_check" => :rerun_check,
    "override_check" => :override_check,
    "draft_contract" => :draft_contract,
    # Milestone 5 (AT-6 and WP13).
    "ask_question" => :ask_question,
    "request_access" => :request_access,
    "report_cost" => :report_cost,
    "start_action" => :start_action,
    "report_action_done" => :report_action_done,
    "create_project" => :create_project,
    "edit_brief" => :edit_brief,
    "pause_project" => :pause_project,
    "resume_project" => :resume_project,
    "change_budget" => :change_budget,
    "delete_project_content" => :delete_project_content,
    "change_task_priority" => :change_task_priority,
    "change_task_project" => :change_task_project,
    "change_task_cap" => :change_task_cap,
    "return_for_rework" => :return_for_rework,
    "offer_task_again" => :offer_task_again,
    "grant_access" => :grant_access,
    "delete_task_content" => :delete_task_content,
    "answer_question" => :answer_question,
    "overturn_answer" => :overturn_answer,
    "approve_action" => :approve_action,
    "stop_action" => :stop_action,
    "waive_action" => :waive_action,
    "mark_action_done" => :mark_action_done,
    "overturn_approval" => :overturn_approval,
    "change_workspace_settings" => :change_workspace_settings,
    # Milestone 6 (CT-1).
    "rename_credential" => :rename_credential,
    "remove_credential" => :remove_credential,
    "reorder_credentials" => :reorder_credentials,
    "refresh_usage" => :refresh_usage,
    "verify_all_credentials" => :verify_all_credentials,
    "report_reading" => :report_reading
  }.freeze

  # A second case for an operation that runs two commands.
  MORE_CASES = {
    "give_verdict (failed)" => [ "give_verdict", :give_failed_verdict ],
    "submit_job_result (a draft)" => [ "submit_job_result", :submit_draft_result ],
    "report_limit (a job)" => [ "report_limit", :report_job_limit ],
    "report_signed_out (a job)" => [ "report_signed_out", :report_job_signed_out ]
  }.freeze

  setup do
    @scenario = Scenario.new
  end

  test "every served operation that changes something has a case, and the one exception is IN-9's" do
    assert_equal HttpCalls.mutating.sort, (CASES.keys + [ SIGN_OUT ]).sort
    assert_equal CASES.keys.sort, CASES.keys.uniq.sort
    MORE_CASES.each_value { |operation, _| assert_includes CASES.keys, operation }
  end

  CASES.merge(MORE_CASES.transform_values(&:last)).each do |name, builder|
    operation = MORE_CASES.dig(name, 0) || name
    test "#{name}: a repeat of the key answers the first outcome and writes nothing" do
      assert_writes_once(operation, send(builder))
    end
  end

  test "sign_out_owner: the first call ends the session, a repeat answers 401 and writes nothing (IN-9)" do
    token = @scenario.owner_token
    key = new_key("sign-out")
    call(SIGN_OUT, token: token, key: key)
    assert_response :ok
    assert_response_matches_contract
    assert_equal "completed", response.parsed_body.fetch("outcome")

    before = counts
    call(SIGN_OUT, token: token, key: key)
    assert_response :unauthorized
    assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
    assert_response_matches_contract
    assert_equal before, counts
  end

  test "a refused command stores its outcome: a repeat answers the same refusal and writes nothing" do
    builder = builder_seat
    key = new_key("refused")
    call("claim_next_task", token: token(builder), key: key)
    assert_response :conflict
    assert_response_matches_contract
    first = response.parsed_body
    assert_equal "not_eligible", first.dig("refusal", "code")

    before = counts
    @scenario.task(state: "ready")
    after_task = counts
    call("claim_next_task", token: token(builder), key: key)
    assert_response :conflict
    assert_equal first, response.parsed_body, "a stored refusal is final for its key"
    assert_equal after_task, counts
    refute_equal before, after_task
  end

  test "approve_action repeats its refusal after approval becomes available" do
    task = finishing_task("requested")
    action = Action.find_by!(task_id: task.id)
    assert_refusal_repeats("approve_action", owner_call(ids: { "id" => action.id }), "invalid_state") do
      open_owner_approval(action)
    end
  end

  test "start_action repeats its refusal after the builder acknowledges the briefing" do
    task = finishing_task("approved")
    assert_refusal_repeats("start_action", action_call(task), "briefing_not_acknowledged") do
      acknowledge(task, builder_seat)
    end
  end

  test "delete_task_content repeats its refusal after the task can be deleted" do
    task = @scenario.task(state: "backlog")
    assert_refusal_repeats("delete_task_content", owner_call(ids: { "id" => task.id }), "invalid_state") do
      engine("cancel", @scenario.owner, { "id" => task.id }, caller_kind: "owner")
    end
  end

  test "a command that waits stores pending: a repeat answers 202 pending and writes nothing" do
    @scenario.with_shipped_rules
    task = @scenario.task(state: "backlog")
    key = new_key("pending")
    call("complete_contract", token: @scenario.owner_token, key: key, ids: { "id" => task.id }, body: contract_body)
    assert_response :accepted
    assert_response_matches_contract
    first = response.parsed_body
    assert_equal "pending", first.fetch("outcome")

    before = counts
    call("complete_contract", token: @scenario.owner_token, key: key, ids: { "id" => task.id }, body: contract_body)
    assert_response :accepted
    assert_equal first, response.parsed_body
    assert_equal before, counts, "a repeat of a waiting command's key wrote something"

    call("complete_contract", token: @scenario.owner_token, key: key, ids: { "id" => task.id }, body: contract_body,
      raw: JSON.pretty_generate(contract_body))
    assert_response :unprocessable_entity
    assert_equal "key_reused", response.parsed_body.dig("error", "code")
    assert_equal before, counts
  end

  test "a legacy job claim receipt gets empty job rules only while its input is available" do
    job = queued_check_job
    seat = orchestrator_seat
    key = new_key
    call("claim_next_job", token: token(seat), key: key)
    assert_response :ok

    receipt = Command.find_by!(caller_id: seat.id, key: key)
    legacy = receipt.result.deep_dup
    legacy.fetch("input").fetch("material").delete("job_rules")
    receipt.update!(result: legacy)
    expected = legacy.deep_dup
    expected.fetch("input").fetch("material")["job_rules"] = []

    call("claim_next_job", token: token(seat), key: key)
    assert_response :ok
    assert_equal expected, response.parsed_body.fetch("result")
    assert_response_matches_contract

    call("get_command", token: token(seat), ids: { "key" => key })
    assert_response :ok
    assert_equal expected, response.parsed_body.fetch("result")
    assert_response_matches_contract
    assert_equal legacy, receipt.reload.result

    engine("submit_job_result", seat, { "id" => job.id, "result" => { "result" => "passed", "reason" => "Made up." },
      "tokens" => 0, "spend" => 0 })
    call("claim_next_job", token: token(seat), key: key)
    assert_response :conflict
    assert_equal [ nil, "not_eligible" ], [ response.parsed_body["result"], response.parsed_body.dig("refusal", "code") ]
  end

  private

  def assert_writes_once(operation, call_data)
    key = new_key(operation.tr("_", "-"))
    call(operation, token: call_data.token, key: key, ids: call_data.ids, body: call_data.body)
    assert_response :ok, "#{operation}: #{response.body}"
    assert_response_matches_contract
    first = response.parsed_body
    assert_equal "completed", first.fetch("outcome")
    assert_equal 1, Command.where(key: key).count, "#{operation} stores one commands row"

    before = counts
    call(operation, token: call_data.token, key: key, ids: call_data.ids, body: call_data.body)
    assert_response :ok, "#{operation} repeated: #{response.body}"
    assert_response_matches_contract
    assert_equal repeated(operation, first), response.parsed_body
    assert_equal before, counts, "#{operation}: a repeat of the key wrote something"

    return unless call_data.body
    # Setup and sign-in hash the body again without its password (IN-9),
    # so the same fields written out differently are the same request.
    return if %w[create_owner sign_in_owner].include?(operation)

    call(operation, token: call_data.token, key: key, ids: call_data.ids, body: call_data.body,
      raw: JSON.pretty_generate(call_data.body))
    assert_response :unprocessable_entity
    assert_equal "key_reused", response.parsed_body.dig("error", "code")
    assert_response_matches_contract
    assert_equal before, counts, "#{operation}: a reused key wrote something"
  end

  def assert_refusal_repeats(operation, call_data, code)
    key = new_key("refused")
    call(operation, token: call_data.token, key: key, ids: call_data.ids, body: call_data.body)
    assert_response :conflict
    assert_response_matches_contract
    first = response.parsed_body
    assert_equal code, first.dig("refusal", "code")
    assert_equal 1, Command.where(key: key, outcome: "refused").count

    yield

    before = counts
    call(operation, token: call_data.token, key: key, ids: call_data.ids, body: call_data.body)
    assert_response :conflict
    assert_response_matches_contract
    assert_equal first, response.parsed_body
    assert_equal before, counts

    call(operation, token: call_data.token, key: new_key, ids: call_data.ids, body: call_data.body)
    assert_response :ok
    assert_response_matches_contract
  end

  # What a repeat answers: the first outcome, or for a token the same ids
  # with "repeated": true and no token.
  def repeated(operation, first)
    field = ONCE[operation]
    return first unless field && first["result"]&.fetch(field, nil)

    once_fields = operation == "issue_landing_prompt" ? [ field, "text" ] : [ field ]
    first.merge("result" => first.fetch("result").except(*once_fields).merge("repeated" => true))
  end

  def counts = TABLES.to_h { |model| [ model.name, model.count ] }

  # --- state ---------------------------------------------------------------

  def token(record) = @scenario.token_for(record)

  def builder_seat = @builder ||= @scenario.seat(role: "builder", credential: @scenario.credential)

  def reviewer_seat = @reviewer ||= @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))

  # Runs a command through the transition function to build state.
  def engine(command, caller, params, caller_kind: "seat")
    request = T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: caller_kind,
      caller_id: caller.id, key: new_key("setup"), request_hash: SecureRandom.hex(32), params: params)
    outcome = T.apply(request)
    assert outcome.completed?, "setup #{command}: #{outcome.refusal&.code}"
    outcome
  end

  def acknowledge(subject, seat)
    command = subject.is_a?(Review) ? "acknowledge_review_briefing" : "acknowledge_briefing"
    engine(command, seat, { "id" => subject.id, "briefing_hash" => Leverage::Briefing.hash_for(subject, seat) })
  end

  # A Working task held by the builder, its briefing acknowledged.
  def working_task
    task = @scenario.task(state: "working", builder: builder_seat)
    acknowledge(task, builder_seat)
    task
  end

  def build_criteria(task) = Criterion.where(task_id: task.id, kind: "build", removed_at: nil).order(:position).to_a

  def evidence(criterion) = { "evidence" => { "kind" => "link", "value" => "https://example.test/made-up/#{criterion.id}" } }

  # An In review task whose open review the reviewer holds, its briefing
  # acknowledged.
  def held_review
    task = @scenario.task(state: "in_review", builder: builder_seat)
    review = @scenario.review(task, reviewer: reviewer_seat)
    acknowledge(review, reviewer_seat)
    review
  end

  def verdict(verdict, failed: [])
    { "verdict" => verdict, "failed_criteria" => failed, "notes" => "Made-up notes.", "tokens" => 10, "spend" => 0 }
  end

  def contract_body
    { "title" => "A made-up task", "details" => "A made-up goal.\n\nMade-up details.",
      "criteria" => [ { "text" => "Made-up build criterion.", "kind" => "build" },
                      { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
      "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => "~/work/made-up" }
  end

  def owner_call(ids: {}, body: nil) = Call.new(token: @scenario.owner_token, ids: ids, body: body)

  def helper_call(ids: {}, body: nil) = Call.new(token: @scenario.helper_token, ids: ids, body: body)

  def queue(kind, seat: nil, credential: nil, params: {})
    HelperRequest.create!(workspace_id: @scenario.workspace_id, kind: kind, seat_id: seat&.id, credential_id: credential&.id,
      state: "picked_up", requested_at: @scenario.database_now, picked_up_at: @scenario.database_now, params: params)
  end

  # --- the cases: agent ----------------------------------------------------

  def claim_next_task
    @scenario.task(state: "ready")
    Call.new(token: token(builder_seat))
  end

  def acknowledge_task_briefing
    task = @scenario.task(state: "working", builder: builder_seat)
    Call.new(token: token(builder_seat), ids: { "id" => task.id },
      body: { "briefing_hash" => Leverage::Briefing.hash_for(task, builder_seat) })
  end

  def heartbeat_task = Call.new(token: token(builder_seat), ids: { "id" => working_task.id })

  def start_criterion
    task = working_task
    Call.new(token: token(builder_seat), ids: { "id" => task.id, "cid" => build_criteria(task).first.id })
  end

  def pass_criterion
    task = working_task
    criterion = build_criteria(task).first
    engine("start_criterion", builder_seat, { "id" => task.id, "cid" => criterion.id })
    Call.new(token: token(builder_seat), ids: { "id" => task.id, "cid" => criterion.id }, body: evidence(criterion))
  end

  def submit_task
    task = working_task
    build_criteria(task).each do |criterion|
      engine("start_criterion", builder_seat, { "id" => task.id, "cid" => criterion.id })
      engine("pass_criterion", builder_seat, { "id" => task.id, "cid" => criterion.id }.merge(evidence(criterion)))
    end
    Call.new(token: token(builder_seat), ids: { "id" => task.id },
      body: { "handoff_note" => "Made-up handoff note.", "work_reference" => "~/work/made-up" })
  end

  def release_task
    Call.new(token: token(builder_seat), ids: { "id" => working_task.id }, body: { "reason" => "unable_to_continue" })
  end

  def claim_next_review
    @scenario.task(state: "in_review", builder: builder_seat)
    Call.new(token: token(reviewer_seat))
  end

  def heartbeat_review = Call.new(token: token(reviewer_seat), ids: { "id" => held_review.id })

  def release_review = Call.new(token: token(reviewer_seat), ids: { "id" => held_review.id })

  def acknowledge_review_briefing
    task = @scenario.task(state: "in_review", builder: builder_seat)
    review = @scenario.review(task, reviewer: reviewer_seat)
    Call.new(token: token(reviewer_seat), ids: { "id" => review.id },
      body: { "briefing_hash" => Leverage::Briefing.hash_for(review, reviewer_seat) })
  end

  def give_passed_verdict
    Call.new(token: token(reviewer_seat), ids: { "id" => held_review.id }, body: verdict("passed"))
  end

  def give_failed_verdict
    review = held_review
    criterion = build_criteria(Task.find(review.task_id)).first
    Call.new(token: token(reviewer_seat), ids: { "id" => review.id }, body: verdict("failed", failed: [ criterion.id ]))
  end

  # --- the cases: owner ----------------------------------------------------

  # Committed tests of other files may have left an owner in this worker's
  # database; inside this test's transaction there is none (IN-2).
  def create_owner
    Session.delete_all
    User.delete_all
    Call.new(token: nil, body: { "email_address" => "owner-#{SecureRandom.hex(4)}@example.test",
                                 "password" => Scenario::PASSWORD })
  end

  def sign_in_owner
    Call.new(token: nil, body: { "email_address" => @scenario.owner.email_address, "password" => Scenario::PASSWORD })
  end

  def add_task
    owner_call(body: { "title" => "A made-up task", "details" => "A made-up goal.", "priority" => "normal",
                       "work_reference" => "~/work/made-up", "state" => "backlog" })
  end

  def complete_contract
    owner_call(ids: { "id" => @scenario.task(state: "backlog").id }, body: contract_body)
  end

  def cancel_task = owner_call(ids: { "id" => @scenario.task(state: "backlog").id })

  # A task held past its round limit: one failed review with a limit of one
  # round opens rounds_exceeded (EN-13).
  def allow_another_round
    @scenario.workspace.update!(maximum_rounds: 1)
    review = held_review
    criterion = build_criteria(Task.find(review.task_id)).first
    engine("fail_review", reviewer_seat, { "id" => review.id }.merge(verdict("failed", failed: [ criterion.id ])))
    assert Hold.exists?(task_id: review.task_id, reason: "rounds_exceeded", closed_at: nil), "the hold is open"
    owner_call(ids: { "id" => review.task_id })
  end

  def issue_landing_prompt
    owner_call(ids: { "id" => @scenario.seat.id }, body: { "connection" => "http" })
  end

  def connect_seat
    owner_call(body: { "name" => "Made-up seat #{SecureRandom.hex(3)}", "role" => "builder", "provider" => "codex",
                       "model" => nil, "effort" => nil, "strength_rank" => nil, "credential_id" => nil })
  end

  def start_seat
    @scenario.helper
    owner_call(ids: { "id" => builder_seat.id })
  end

  def stop_seat
    @scenario.helper
    seat = @scenario.seat(role: "builder", credential: @scenario.credential, run_state: "running", wanted_running: true)
    owner_call(ids: { "id" => seat.id })
  end

  def remove_seat = owner_call(ids: { "id" => @scenario.seat(role: "builder", provider: "codex").id })

  def issue_helper_token = owner_call(body: { "name" => "Made-up Mac" })

  def add_credential
    @scenario.helper
    owner_call(body: { "credential_id" => SecureRandom.uuid, "kind" => "login", "provider" => "claude",
                       "name" => "Made-up login #{SecureRandom.hex(3)}", "masked_label" => nil, "model" => nil,
                       "effort" => nil, "strength_rank" => nil })
  end

  def verify_credential
    @scenario.helper
    owner_call(ids: { "id" => @scenario.credential.id })
  end

  def rename_credential
    owner_call(ids: { "id" => @scenario.credential.id }, body: { "name" => "Renamed account" })
  end

  def remove_credential
    owner_call(ids: { "id" => @scenario.token_credential.id })
  end

  def reorder_credentials
    logins = Array.new(3) { @scenario.credential }
    owner_call(body: { "order" => logins.rotate.map(&:id) })
  end

  def refresh_usage
    @scenario.helper
    @scenario.credential
    owner_call
  end

  def verify_all_credentials
    @scenario.helper
    @scenario.credential
    @scenario.token_credential
    owner_call
  end

  def report_reading
    id = @scenario.credential.id
    helper_call(ids: { "id" => id }, body: { "credential_id" => id, "observed_at" => @scenario.database_now.utc.iso8601(6),
      "state" => "unavailable", "figures" => [], "resets" => nil, "tool_version" => nil })
  end

  def install_tool
    @scenario.helper
    owner_call(ids: { "provider" => "claude" }, body: { "confirmed" => true })
  end

  # --- the cases: helper ---------------------------------------------------

  def add_request
    credential = @scenario.credential(added: false)
    queue("run_add_checks", credential: credential, params: { "provider" => "claude", "credential_kind" => "login" })
  end

  def report_request_progress
    helper_call(ids: { "id" => add_request.id },
      body: { "check" => "tool_installed", "state" => "running", "failure" => nil, "install" => nil })
  end

  def report_request_result
    checks = %w[tool_installed signed_in test_prompt].map { |name| { "check" => name, "passed" => true, "failure" => nil } }
    helper_call(ids: { "id" => add_request.id },
      body: { "result" => { "outcome" => "finished", "checks" => checks, "tool_version" => "9.9.9-made-up", "plan" => nil,
                            "account_email" => nil } })
  end

  def issue_seat_token
    seat = @scenario.seat(role: "builder", credential: @scenario.credential, token: false)
    start = queue("start_seat", seat: seat, params: { "role" => "builder", "provider" => "claude" })
    helper_call(ids: { "id" => start.id })
  end

  def report_run_started
    seat = builder_seat
    helper_call(ids: { "id" => seat.id }, body: { "credential_id" => seat.credential_id,
                                                  "observed_at" => Time.current.utc.iso8601, "tool_version" => "9.9.9-made-up" })
  end

  def report_run_stopped
    seat = @scenario.seat(role: "builder", credential: @scenario.credential, run_state: "running", wanted_running: true)
    helper_call(ids: { "id" => seat.id }, body: { "credential_id" => seat.credential_id,
                                                  "observed_at" => Time.current.utc.iso8601, "stop_reason" => "finished" })
  end

  # --- the cases: milestone 3 ----------------------------------------------

  # The helper's two reports about the Working task the builder holds on
  # its own login, with a second login below it to hand over to.
  def report_body(task)
    @scenario.credential(provider: "codex")
    { "credential_id" => builder_seat.credential_id, "seat_id" => builder_seat.id, "task_id" => task.id,
      "review_id" => nil, "job_id" => nil, "observed_at" => @scenario.database_now.utc.iso8601(6),
      "tool_version" => "0.0.0-made-up" }
  end

  def report_limit
    body = report_body(working_task).merge("window" => "five_hour",
      "reset_at" => (@scenario.database_now + 3600).utc.iso8601(6))
    helper_call(ids: { "id" => builder_seat.credential_id }, body: body)
  end

  def report_signed_out
    helper_call(ids: { "id" => builder_seat.credential_id }, body: report_body(working_task))
  end

  def sign_in_again
    @scenario.helper
    owner_call(ids: { "id" => @scenario.credential(state: "signed_out").id })
  end

  def promote_task = owner_call(ids: { "id" => @scenario.task(state: "imaginarium").id })

  def edit_contract = owner_call(ids: { "id" => @scenario.task(state: "backlog").id }, body: contract_body)

  def hold_task = owner_call(ids: { "id" => @scenario.task(state: "ready").id })

  def resume_task
    task = @scenario.task(state: "ready")
    engine("hold", @scenario.owner, { "id" => task.id }, caller_kind: "owner")
    owner_call(ids: { "id" => task.id })
  end

  def pause_seat = owner_call(ids: { "id" => builder_seat.id })

  def resume_seat
    @scenario.pause_seat(builder_seat)
    owner_call(ids: { "id" => builder_seat.id })
  end

  def change_seat
    owner_call(ids: { "id" => builder_seat.id },
      body: { "name" => "Made-up agent #{SecureRandom.hex(3)}", "model" => nil, "effort" => "high", "strength_rank" => 2 })
  end

  # --- the cases: milestone 4 ----------------------------------------------

  def orchestrator_seat
    @orchestrator ||= @scenario.orchestrator(credential: @scenario.credential(provider: "codex"))
  end

  def planner_seat = @planner ||= @scenario.planner(credential: @scenario.credential(provider: "claude"))

  # A rule check in the queue: Complete contract waits for a blocking model
  # rule at "ready to start" (RE-2), the only rule of the workspace.
  def queued_check_job
    @scenario.rule(hook: "task.before_ready", route: "owner")
    task = @scenario.task(state: "backlog")
    outcome = T.apply(T::Request.new(command: "complete_contract", workspace_id: @scenario.workspace_id,
      caller_kind: "owner", caller_id: @scenario.owner.id, key: new_key("setup"), request_hash: SecureRandom.hex(32),
      params: contract_body.merge("id" => task.id)))
    assert_equal :pending, outcome.outcome, "setup complete_contract waits for its check"
    Job.find_by!(workspace_id: @scenario.workspace_id, task_id: task.id, state: "queued")
  end

  def claimed(job, seat)
    engine("claim_job", seat, {})
    job.reload
  end

  def claim_next_job
    queued_check_job
    Call.new(token: token(orchestrator_seat))
  end

  def submit_check_result
    job = claimed(queued_check_job, orchestrator_seat)
    Call.new(token: token(orchestrator_seat), ids: { "id" => job.id },
      body: { "result" => { "result" => "passed", "reason" => "Made-up reason." }, "tokens" => 120, "spend" => 0 })
  end

  # A planner's draft in a workspace with no rule: its Complete contract
  # completes at once (RE-6).
  def submit_draft_result
    task = @scenario.task(state: "backlog")
    engine("draft_contract", @scenario.owner, { "id" => task.id }, caller_kind: "owner")
    job = claimed(Job.find_by!(workspace_id: @scenario.workspace_id, task_id: task.id, state: "queued"), planner_seat)
    Call.new(token: token(planner_seat), ids: { "id" => job.id },
      body: { "result" => contract_body, "tokens" => 900, "spend" => 0 })
  end

  def rule_scope = { "kind" => "all_tasks", "project_ids" => [], "action_kinds" => [] }

  def add_rule
    owner_call(body: { "name" => "Names the page #{SecureRandom.hex(3)}", "instruction" => "The details name the page.",
                       "hook" => "task.before_submit", "scope" => rule_scope })
  end

  def save_rule
    rule = @scenario.rule
    owner_call(ids: { "id" => rule.id },
      body: { "name" => "Names the page", "instruction" => "The details name the page it changes.", "parameters" => nil,
              "scope" => rule_scope, "on_fail" => "block", "route" => "builder", "queue_timeout_seconds" => nil,
              "run_timeout_seconds" => nil })
  end

  def enable_rule = owner_call(ids: { "id" => @scenario.rule(enabled: false).id })

  def disable_rule = owner_call(ids: { "id" => @scenario.rule.id })

  def revert_rule
    owner_call(ids: { "id" => @scenario.rule(key: "acceptance_criteria", origin: "shipped", versions: 2,
      parameters: { "minimum_count" => 3 }).id })
  end

  def remove_rule = owner_call(ids: { "id" => @scenario.rule.id })

  def rerun_check
    rule = @scenario.rule
    task = @scenario.task(state: "working", builder: builder_seat)
    check = @scenario.rule_check(task, rule: rule, result: "error", started: true)
    owner_call(ids: { "id" => check.id })
  end

  # The acceptance-criteria rule fails a contract with no build criterion:
  # the contract is kept under contract_incomplete (RD-10), and the failed
  # check is what the owner lets through.
  def override_check
    @scenario.with_shipped_rules(off: %w[specific_details])
    task = @scenario.task(state: "backlog")
    body = contract_body.merge("criteria" => [ { "text" => "An independent reviewer agrees.", "kind" => "review" } ])
    engine("complete_contract", @scenario.owner, body.merge("id" => task.id), caller_kind: "owner")
    check = RuleCheck.find_by!(task_id: task.id, result: "failed")
    owner_call(ids: { "id" => check.id }, body: { "reason" => "Made-up reason to let it through." })
  end

  def draft_contract = owner_call(ids: { "id" => @scenario.task(state: "backlog").id })

  # The helper's two reports about the job the orchestrator holds on its
  # own login, with a second login below it to hand over to.
  def job_report_body
    job = claimed(queued_check_job, orchestrator_seat)
    @scenario.credential(provider: "grok")
    { "credential_id" => orchestrator_seat.credential_id, "seat_id" => orchestrator_seat.id, "task_id" => nil,
      "review_id" => nil, "job_id" => job.id, "observed_at" => @scenario.database_now.utc.iso8601(6),
      "tool_version" => "0.0.0-made-up" }
  end

  def report_job_limit
    body = job_report_body.merge("window" => "five_hour", "reset_at" => (@scenario.database_now + 3600).utc.iso8601(6))
    helper_call(ids: { "id" => orchestrator_seat.credential_id }, body: body)
  end

  def report_job_signed_out = helper_call(ids: { "id" => orchestrator_seat.credential_id }, body: job_report_body)

  # --- the cases: milestone 5 ----------------------------------------------

  def ask_question
    Call.new(token: token(builder_seat), ids: { "id" => working_task.id },
      body: { "text" => "What should I use?", "assumption" => "Use the sample.", "blocking" => false })
  end

  def request_access
    Call.new(token: token(builder_seat), ids: { "id" => working_task.id },
      body: { "description" => "Open the sample folder." })
  end

  def report_cost
    Call.new(token: token(builder_seat), ids: { "id" => working_task.id }, body: { "tokens" => 10, "spend" => 0.01 })
  end

  def start_action
    task = finishing_task("approved")
    acknowledge(task, builder_seat)
    action_call(task)
  end

  def report_action_done
    task = finishing_task("started")
    acknowledge(task, builder_seat)
    action_call(task)
  end

  def create_project
    owner_call(body: { "name" => "Made-up project", "goal" => "Track the sample.", "budget" => 100 })
  end

  def edit_brief
    owner_call(ids: { "id" => @scenario.project.id },
      body: { "entries" => [ { "kind" => "decision", "text" => "Use the sample." } ] })
  end

  def pause_project = owner_call(ids: { "id" => @scenario.project.id })

  def resume_project
    project = @scenario.project
    engine("pause_project", @scenario.owner, { "id" => project.id }, caller_kind: "owner")
    owner_call(ids: { "id" => project.id })
  end

  def change_budget = owner_call(ids: { "id" => @scenario.project.id }, body: { "budget" => 50 })

  def delete_project_content
    project = @scenario.project(brief: [ { kind: "rule", text: "A made-up brief entry." } ])
    engine("pause_project", @scenario.owner, { "id" => project.id }, caller_kind: "owner")
    owner_call(ids: { "id" => project.id })
  end

  def change_task_priority
    owner_call(ids: { "id" => @scenario.task.id }, body: { "priority" => "high" })
  end

  def change_task_project
    owner_call(ids: { "id" => @scenario.task.id }, body: { "project_id" => @scenario.project.id })
  end

  def change_task_cap
    owner_call(ids: { "id" => @scenario.task.id }, body: { "budget_cap" => 25 })
  end

  def return_for_rework
    task = finishing_task("stopped")
    owner_call(ids: { "id" => task.id }, body: { "criterion_ids" => [ build_criteria(task).first.id ] })
  end

  def offer_task_again = owner_call(ids: { "id" => unconfirmed_task.id })

  def grant_access
    task = working_task
    engine("request_access", builder_seat, { "id" => task.id, "description" => "Open the sample folder." })
    owner_call(ids: { "id" => task.id })
  end

  def delete_task_content
    owner_call(ids: { "id" => @scenario.task(state: "cancelled").id })
  end

  def answer_question
    question = @scenario.question(working_task, outcome: "passed_on")
    owner_call(ids: { "id" => question.id }, body: { "answer" => "Use the sample." })
  end

  def overturn_answer
    question = @scenario.question(working_task, outcome: "answered")
    owner_call(ids: { "id" => question.id })
  end

  def approve_action
    action = Action.find_by!(task_id: finishing_task("requested").id)
    open_owner_approval(action)
    owner_call(ids: { "id" => action.id })
  end

  def stop_action = owner_action_call(finishing_task("requested"))

  def waive_action = owner_action_call(finishing_task("stopped"))

  def mark_action_done = owner_action_call(unconfirmed_task)

  def overturn_approval
    task = finishing_task("approved")
    Action.find_by!(task_id: task.id).update!(approved_by_kind: "seat", approved_by_id: orchestrator_seat.id)
    owner_action_call(task)
  end

  def change_workspace_settings = owner_call(body: { "lease_length_seconds" => 900 })

  def finishing_task(state)
    @scenario.finishing_task(builder: builder_seat,
      actions: [ { kind: "publish", description: "Publish a sample.", state: state } ])
  end

  def unconfirmed_task
    task = finishing_task("approved")
    engine("release", builder_seat, { "id" => task.id, "reason" => "unable_to_continue" })
    task
  end

  def open_owner_approval(action)
    @scenario.hold(Task.find(action.task_id), reason: "owner_approval", facts: { action_id: action.id })
  end

  def owner_action_call(task) = owner_call(ids: { "id" => Action.find_by!(task_id: task.id).id })

  def action_call(task)
    Call.new(token: token(builder_seat), ids: { "id" => task.id, "aid" => Action.find_by!(task_id: task.id).id })
  end
end
