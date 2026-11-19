require "test_helper"
require_relative "../support/http_calls"

# Test 5 (PRD L838, L917; milestone 2 plan IN-8 to IN-11, WP17): every
# served operation that changes something, taken from Http::RouteTable and
# the registry, is sent over HTTP through the real entries and then sent
# again with the same key and the same body. The repeat answers what the
# first call answered (for the four answers that carry a token: the same
# ids with "repeated": true and no token, IN-11) and writes nothing: no
# event, no commands row, no other row. The same key with another body (the
# same fields written out differently: the request hash is over the raw
# bytes, IN-8) is 422 key_reused and writes nothing either.
#
# The one exception is IN-9's: a repeat of sign-out answers 401 and writes
# nothing, because the session that would prove who asks is what the first
# call ended.
class IdempotencyHttpTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  T = Leverage::Transitions

  # The exception test 5 names (IN-9).
  SIGN_OUT = "sign_out_owner".freeze

  # The token field of the four answers that carry a token, by operation.
  ONCE = {
    "create_owner" => "session_token", "sign_in_owner" => "session_token", "issue_helper_token" => "helper_token",
    "connect_seat" => "seat_token", "issue_seat_token" => "seat_token"
  }.freeze

  # Every table a command can write, counted before and after a repeat.
  TABLES = [
    Event, Command, Task, Criterion, Evidence, Review, TaskStep, Hold, BriefingAcknowledgement, Seat, Credential,
    HelperRequest, Helper, Session, User, Workspace, InboxItem
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
    "report_run_stopped" => :report_run_stopped
  }.freeze

  # A second case for an operation that runs two commands.
  MORE_CASES = { "give_verdict (failed)" => [ "give_verdict", :give_failed_verdict ] }.freeze

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

  # What a repeat answers: the first outcome, or for a token the same ids
  # with "repeated": true and no token.
  def repeated(operation, first)
    field = ONCE[operation]
    return first unless field && first["result"]&.fetch(field, nil)

    first.merge("result" => first.fetch("result").except(field).merge("repeated" => true))
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
    { "title" => "A made-up task", "goal" => "A made-up goal.", "details" => "Made-up details.",
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
    owner_call(body: { "title" => "A made-up task", "goal" => "A made-up goal.", "priority" => "normal",
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
end
