require "test_helper"
require_relative "../support/http_calls"

# No seat reaches outside the Roles table (PRD Roles, L548, L823, L918,
# L921; milestone 2 plan WP17; milestone 4 plan WP13), over HTTP through
# the real entries, for the four roles: the builder and the reviewer of
# milestone 2, and milestone 4's two job roles, the orchestrator and the
# planner:
#
# - every served agent operation is in the Roles table of a role, and a
#   seat of another role is refused it: a claim is not_eligible, a briefing
#   read is 404, a question read is not_holder, and any other call is refused by a cause that ranks no lower than
#   forbidden (L548: lease_expired, task_cancelled, not_holder, forbidden);
# - a seat of the wrong role that holds the very task or review the call
#   names is refused forbidden;
# - a seat of the right role that does not hold it is refused not_holder;
# - a refused call writes nothing and moves nothing;
# - Connect offers the four roles (milestone 4 plan §0.1 fact 12, RV-5);
# - neither a seat's token nor the owner's session reaches a helper call:
#   each is 401, the two reports of milestone 3 among them (its plan
#   WP10), and nothing is written.
class SeatRolesTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  T = Leverage::Transitions

  ROLES = Leverage::Contract.load("roles.json").fetch("roles").to_h { |role| [ role.fetch("role"), role.fetch("operations") ] }

  SERVED_AGENT = HttpCalls.served.select { |op| op.fetch("tag") == "agent" }.map { |op| op.fetch("operation_id") }.freeze

  # The calls about a task the builder holds, and about a review the
  # reviewer holds: what each sends besides the path's id.
  TASK_CALLS = %w[acknowledge_task_briefing heartbeat_task start_criterion pass_criterion submit_task release_task
                  ask_question request_access report_cost].freeze
  ACTION_CALLS = { "start_action" => "approved", "report_action_done" => "started" }.freeze
  REVIEW_CALLS = %w[heartbeat_review release_review acknowledge_review_briefing give_verdict].freeze
  CLAIMS = { "builder" => "claim_next_task", "reviewer" => "claim_next_review" }.freeze
  # The two job roles' calls (roles.json): a claim, and a result about the
  # job the seat holds.
  JOB_CALLS = %w[claim_next_job submit_job_result].freeze
  JOB_ROLES = %w[orchestrator planner].freeze
  READS = { "get_task_briefing" => :task, "get_review_briefing" => :review }.freeze

  # Ranked no lower than forbidden in L548's order.
  HOLDER_CAUSES = %w[lease_expired task_cancelled not_holder forbidden].freeze

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
  end

  test "every served agent operation is in the Roles table, and each role's served calls are covered here" do
    assert_equal %w[builder orchestrator planner reviewer], ROLES.keys.sort
    SERVED_AGENT.each do |operation_id|
      assert(ROLES.keys.any? { |role| ROLES.fetch(role).include?(operation_id) }, operation_id)
    end
    covered = TASK_CALLS + ACTION_CALLS.keys + REVIEW_CALLS + CLAIMS.values + READS.keys + JOB_CALLS +
      %w[get_next get_command get_question]
    assert_equal SERVED_AGENT.sort, covered.sort
    builder_only = TASK_CALLS + ACTION_CALLS.keys + %w[get_question]
    assert_empty builder_only - ROLES.fetch("builder")
    (ROLES.keys - [ "builder" ]).each do |role|
      assert_empty builder_only & ROLES.fetch(role), role
    end
    REVIEW_CALLS.each { |operation_id| refute_includes ROLES.fetch("builder"), operation_id }
    JOB_ROLES.each do |role|
      assert_equal (JOB_CALLS + %w[get_next get_command]).sort, (ROLES.fetch(role) & SERVED_AGENT).sort, role
    end
    JOB_CALLS.each { |operation_id| %w[builder reviewer].each { |role| refute_includes ROLES.fetch(role), operation_id } }
  end

  test "a builder or a reviewer cannot claim a job, and a job role cannot claim a task or a review: not_eligible" do
    waiting_job
    ready = @scenario.task(state: "ready")
    in_review = @scenario.task(state: "in_review")
    [ @builder, @reviewer ].each { |seat| refused("claim_next_job", seat, codes: %w[not_eligible]) }
    job_seats.each_value do |seat|
      refused("claim_next_task", seat, codes: %w[not_eligible])
      refused("claim_next_review", seat, codes: %w[not_eligible])
    end
    assert_equal "ready", ready.reload.state
    assert_nil Review.find_by(task_id: in_review.id).reviewer_seat_id
    assert_equal [ "queued" ], Job.where(workspace_id: @scenario.workspace_id).pluck(:state)
  end

  test "submit_job_result: a seat of another role is refused, one of the right role not_holder, a holder of the wrong role forbidden" do
    job = claimed_job(job_seats.fetch("orchestrator"))
    body = { "result" => { "result" => "passed", "reason" => "Made-up reason." }, "tokens" => 0, "spend" => 0 }
    [ @builder, @reviewer, job_seats.fetch("planner") ].each do |seat|
      refused("submit_job_result", seat, ids: { "id" => job.id }, body: body, codes: HOLDER_CAUSES)
    end
    other = @scenario.orchestrator(credential: @scenario.credential(provider: "grok"))
    refused("submit_job_result", other, ids: { "id" => job.id }, body: body, codes: %w[not_holder])

    held = @scenario.job(kind: "rule_check", task: @scenario.task(state: "backlog"), state: "claimed", seat: @builder)
    refused("submit_job_result", @builder, ids: { "id" => held.id }, body: body, codes: %w[forbidden])
    assert_equal "claimed", job.reload.state
  end

  test "a job role is refused every task and review call: on another's work, and forbidden on work it holds" do
    orchestrator = job_seats.fetch("orchestrator")
    task = working_task(@builder)
    TASK_CALLS.each do |operation_id|
      refused(operation_id, orchestrator, ids: task_ids(operation_id, task), body: task_body(operation_id, task),
        codes: HOLDER_CAUSES)
    end
    review = open_review_of(@scenario.task(state: "in_review"), @reviewer)
    REVIEW_CALLS.each do |operation_id|
      refused(operation_id, orchestrator, ids: { "id" => review.id }, body: review_body(operation_id, review),
        codes: HOLDER_CAUSES)
    end
    held = working_task(orchestrator, acknowledge: false)
    TASK_CALLS.each do |operation_id|
      refused(operation_id, orchestrator, ids: task_ids(operation_id, held), body: task_body(operation_id, held),
        codes: %w[forbidden])
    end
  end

  test "a reviewer cannot claim a task and a builder cannot claim a review: not_eligible, nothing written" do
    ready = @scenario.task(state: "ready")
    in_review = @scenario.task(state: "in_review")
    { @reviewer => "claim_next_task", @builder => "claim_next_review" }.each do |seat, operation_id|
      refused(operation_id, seat, codes: %w[not_eligible])
    end
    assert_equal "ready", ready.reload.state
    assert_nil Review.find_by(task_id: in_review.id).reviewer_seat_id
  end

  test "a seat cannot read the briefing of the other role's work: 404" do
    task = @scenario.task(state: "working", builder: @builder)
    review = open_review_of(@scenario.task(state: "in_review"), @reviewer)
    call("get_task_briefing", token: token(@reviewer), ids: { "id" => task.id })
    assert_response :not_found
    assert_response_matches_contract
    call("get_review_briefing", token: token(@builder), ids: { "id" => review.id })
    assert_response :not_found
    assert_response_matches_contract
  end

  TASK_CALLS.each do |operation_id|
    test "#{operation_id}: the reviewer is refused on the builder's task, and forbidden on one it holds" do
      task = working_task(@builder)
      refused(operation_id, @reviewer, ids: task_ids(operation_id, task), body: task_body(operation_id, task),
        codes: HOLDER_CAUSES)

      held = working_task(@reviewer, acknowledge: false)
      refused(operation_id, @reviewer, ids: task_ids(operation_id, held), body: task_body(operation_id, held),
        codes: %w[forbidden])
    end

    test "#{operation_id}: another builder is refused not_holder" do
      task = working_task(@builder)
      other = @scenario.seat(role: "builder")
      refused(operation_id, other, ids: task_ids(operation_id, task), body: task_body(operation_id, task),
        codes: %w[not_holder])
    end
  end

  ACTION_CALLS.each do |operation_id, state|
    test "#{operation_id}: only the builder holding the Finishing task can act" do
      ids = finishing_ids(@builder, state)
      other = @scenario.seat(role: "builder")
      refused(operation_id, other, ids: ids, codes: %w[not_holder])
      [ @reviewer, *job_seats.values ].each do |seat|
        refused(operation_id, seat, ids: ids, codes: HOLDER_CAUSES)
        refused(operation_id, seat, ids: finishing_ids(seat, state), codes: %w[forbidden])
      end
    end
  end

  test "get_question: only the builder who asked and still holds the task can read the answer" do
    task = working_task(@builder)
    question = @scenario.question(task, outcome: "answered", blocking: false)
    ids = { "id" => task.id, "qid" => question.id }
    other_seats = [ @scenario.seat(role: "builder"), @reviewer, *job_seats.values ]
    before = counts
    other_seats.each do |seat|
      call("get_question", token: token(seat), ids: ids)
      assert_response :conflict
      assert_equal "not_holder", response.parsed_body.fetch("code")
      assert_response_matches_contract
    end
    assert_equal before, counts
    assert_nil question.reload.read_at
  end

  REVIEW_CALLS.each do |operation_id|
    test "#{operation_id}: the builder is refused on the reviewer's review, and forbidden on one it holds" do
      review = open_review_of(@scenario.task(state: "in_review"), @reviewer)
      refused(operation_id, @builder, ids: { "id" => review.id }, body: review_body(operation_id, review),
        codes: HOLDER_CAUSES)

      other_builder = @scenario.seat(role: "builder")
      held = open_review_of(@scenario.task(state: "in_review", builder: other_builder), @builder, acknowledge: false)
      refused(operation_id, @builder, ids: { "id" => held.id }, body: review_body(operation_id, held), codes: %w[forbidden])
    end

    test "#{operation_id}: another reviewer is refused not_holder" do
      review = open_review_of(@scenario.task(state: "in_review"), @reviewer)
      other = @scenario.seat(role: "reviewer")
      refused(operation_id, other, ids: { "id" => review.id }, body: review_body(operation_id, review),
        codes: %w[not_holder])
    end
  end

  # Milestone 4 (its plan §0.1 fact 12, RV-5): Connect offers the four
  # roles; a planner or an orchestrator connects as a builder does, on its
  # own or on a login, with no rule on its provider or model.
  test "Connect offers the four roles: a planner or an orchestrator connects like a builder" do
    login = @scenario.credential(provider: "grok")
    { "planner" => nil, "orchestrator" => login.id }.each do |role, credential_id|
      call("connect_seat", token: @scenario.owner_token, key: new_key,
        body: { "name" => "Made-up #{role}", "role" => role, "provider" => (credential_id ? nil : "codex"),
                "model" => nil, "effort" => nil, "strength_rank" => nil, "credential_id" => credential_id })
      assert_response :ok, response.body
      assert_response_matches_contract
      assert_equal "completed", response.parsed_body.fetch("outcome")
      seat = Seat.find(response.parsed_body.dig("result", "seat_id"))
      assert_equal [ role, credential_id ], [ seat.role, seat.credential_id ]
    end
  end

  SERVED_HELPER = HttpCalls.served.select { |op| op.fetch("tag") == "helper" }.map { |op| op.fetch("operation_id") }.freeze

  test "a seat's token and the owner's session are 401 on every helper call, and nothing is written" do
    assert_includes SERVED_HELPER, "report_limit"
    assert_includes SERVED_HELPER, "report_signed_out"
    SERVED_HELPER.each do |operation_id|
      ids = HttpCalls.operation(operation_id).fetch("path").scan(/\{([a-z]+)\}/).flatten.to_h { |name| [ name, SecureRandom.uuid ] }
      [ token(@builder), token(@reviewer), @scenario.owner_token ].each do |caller_token|
        unauthenticated(operation_id, caller_token, ids: ids)
      end
    end
  end

  test "the builder's own token, the reviewer's and the owner's session are 401 on the reports about the builder's work" do
    task = working_task(@builder)
    @scenario.credential(provider: "codex")
    report = { "credential_id" => @builder.credential_id, "seat_id" => @builder.id, "task_id" => task.id,
               "review_id" => nil, "job_id" => nil, "observed_at" => @scenario.database_now.utc.iso8601(6),
               "tool_version" => "0.0.0-made-up" }
    bodies = { "report_limit" => report.merge("window" => "five_hour",
                                             "reset_at" => (@scenario.database_now + 3600).utc.iso8601(6)),
               "report_signed_out" => report }
    bodies.each do |operation_id, body|
      [ token(@builder), token(@reviewer), @scenario.owner_token ].each do |caller_token|
        unauthenticated(operation_id, caller_token, ids: { "id" => @builder.credential_id }, body: body)
      end
    end
    assert_equal [ "working", @builder.id ], task.reload.values_at(:state, :holder_seat_id)
    assert_nil Credential.find(@builder.credential_id).limited_since
    assert_equal "active", Credential.find(@builder.credential_id).state
  end

  private

  def token(seat) = @scenario.token_for(seat)

  # An orchestrator on a Codex login and a planner on a Claude login.
  def job_seats
    @job_seats ||= { "orchestrator" => @scenario.orchestrator(credential: @scenario.credential(provider: "codex")),
                     "planner" => @scenario.planner(credential: @scenario.credential(provider: "claude")) }
  end

  # A rule check waiting in the queue: a Complete contract under a blocking
  # model rule at "ready to start" waits for it (RD-30, RE-2).
  def waiting_job
    rule = @scenario.rule(hook: "task.before_ready", route: "owner")
    task = @scenario.task(state: "backlog")
    params = { "id" => task.id, "title" => task.title, "goal" => "Made-up goal.", "details" => "Made-up details.",
               "criteria" => [ { "text" => "Made-up criterion.", "kind" => "build" },
                               { "text" => "An independent reviewer agrees.", "kind" => "review" } ],
               "actions" => [], "minimum_strength_rank" => nil, "budget_cap" => nil, "work_reference" => "~/work/made-up" }
    outcome = T.apply(T::Request.new(command: "complete_contract", workspace_id: @scenario.workspace_id, caller_kind: "owner",
      caller_id: @scenario.owner.id, key: new_key("setup"), request_hash: SecureRandom.hex(32), params: params))
    assert_equal :pending, outcome.outcome, "setup complete_contract waits for #{rule.key}'s check"
    Job.find_by!(workspace_id: @scenario.workspace_id, target_kind: "rule_check", state: "queued")
  end

  # The waiting job, claimed by seat.
  def claimed_job(seat)
    job = waiting_job
    engine("claim_job", seat, {})
    job.reload
  end

  # Sends the call with a token that is not the helper's: 401, nothing run.
  def unauthenticated(operation_id, caller_token, ids:, body: nil)
    before = [ Event.count, Command.count, HelperRequest.count, Hold.count ]
    call(operation_id, token: caller_token, key: new_key, ids: ids, body: body, check_request: !body.nil?)
    assert_response :unauthorized, "#{operation_id}: #{response.body}"
    assert_equal "unauthenticated", response.parsed_body.dig("error", "code"), operation_id
    assert_response_matches_contract
    assert_equal before, [ Event.count, Command.count, HelperRequest.count, Hold.count ], operation_id
  end

  def counts = [ Event.count, Command.where.not(outcome: "refused").count, Task.pluck(:state, :holder_seat_id).sort_by(&:to_s) ]

  # Sends the call and holds it to a refusal with one of codes, nothing
  # written but the refused commands row.
  def refused(operation_id, seat, codes:, ids: {}, body: nil)
    before = counts
    events = Event.count
    call(operation_id, token: token(seat), key: new_key, ids: ids, body: body)
    assert_response :conflict, "#{operation_id} by the #{seat.role}: #{response.body}"
    assert_response_matches_contract
    assert_includes codes, response.parsed_body.dig("refusal", "code"), "#{operation_id} by the #{seat.role}"
    assert_equal events, Event.count, "#{operation_id}: a refusal wrote an event"
    assert_equal before, counts
  end

  def engine(command, seat, params)
    outcome = T.apply(T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat",
      caller_id: seat.id, key: new_key("setup"), request_hash: SecureRandom.hex(32), params: params))
    assert outcome.completed?, "setup #{command}: #{outcome.refusal&.code}"
  end

  # A Working task held by seat (whatever its role), its briefing
  # acknowledged unless acknowledge: false. A seat of the wrong role cannot
  # acknowledge (forbidden), and needs not: forbidden ranks before
  # briefing_not_acknowledged (L548).
  def working_task(seat, acknowledge: true)
    task = @scenario.task(state: "working", builder: seat)
    engine("acknowledge_briefing", seat, { "id" => task.id, "briefing_hash" => Leverage::Briefing.hash_for(task, seat) }) if acknowledge
    task
  end

  # The open review of an In review task, held by seat (whatever its role),
  # its briefing acknowledged unless acknowledge: false.
  def open_review_of(task, seat, acknowledge: true)
    review = @scenario.review(task, reviewer: seat)
    if acknowledge
      engine("acknowledge_review_briefing", seat,
        { "id" => review.id, "briefing_hash" => Leverage::Briefing.hash_for(review, seat) })
    end
    review
  end

  def criterion(task) = Criterion.where(task_id: task.id, kind: "build").order(:position).first

  def task_ids(operation_id, task)
    %w[start_criterion pass_criterion].include?(operation_id) ? { "id" => task.id, "cid" => criterion(task).id } : { "id" => task.id }
  end

  def finishing_ids(seat, action_state)
    task = @scenario.finishing_task(builder: seat, holder: true,
      actions: [ { kind: "publish", description: "Publish a sample.", state: action_state } ])
    { "id" => task.id, "aid" => Action.find_by!(task_id: task.id).id }
  end

  def task_body(operation_id, task)
    case operation_id
    when "acknowledge_task_briefing" then { "briefing_hash" => Leverage::Briefing.hash_for(task, @builder) }
    when "pass_criterion" then { "evidence" => { "kind" => "link", "value" => "https://example.test/made-up" } }
    when "submit_task" then { "handoff_note" => "Made-up note.", "work_reference" => "~/work/made-up" }
    when "release_task" then { "reason" => "unable_to_continue" }
    when "ask_question" then { "text" => "What should I use?", "assumption" => "Use the sample.", "blocking" => true }
    when "request_access" then { "description" => "Open the sample folder." }
    when "report_cost" then { "tokens" => 10, "spend" => 0 }
    end
  end

  def review_body(operation_id, review)
    case operation_id
    when "acknowledge_review_briefing" then { "briefing_hash" => Leverage::Briefing.hash_for(review, @reviewer) }
    when "give_verdict"
      { "verdict" => "passed", "failed_criteria" => [], "notes" => "Made-up notes.", "tokens" => 0, "spend" => 0 }
    end
  end
end
