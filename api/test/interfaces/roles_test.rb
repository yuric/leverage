require "test_helper"
require_relative "../support/http_calls"

# No seat reaches outside the Roles table (PRD Roles, L548, L823, L918;
# milestone 2 plan WP17), over HTTP through the real entries, for the two
# roles milestone 2 connects:
#
# - every served agent operation is in the Roles table of a role, and a
#   seat of the other role is refused it: a claim is not_eligible, a read
#   is 404, any other call is refused by a cause that ranks no lower than
#   forbidden (L548: lease_expired, task_cancelled, not_holder, forbidden);
# - a seat of the wrong role that holds the very task or review the call
#   names is refused forbidden;
# - a seat of the right role that does not hold it is refused not_holder;
# - a refused call writes nothing and moves nothing.
class SeatRolesTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  T = Leverage::Transitions

  ROLES = Leverage::Contract.load("roles.json").fetch("roles").to_h { |role| [ role.fetch("role"), role.fetch("operations") ] }

  SERVED_AGENT = HttpCalls.served.select { |op| op.fetch("tag") == "agent" }.map { |op| op.fetch("operation_id") }.freeze

  # The calls about a task the builder holds, and about a review the
  # reviewer holds: what each sends besides the path's id.
  TASK_CALLS = %w[acknowledge_task_briefing heartbeat_task start_criterion pass_criterion submit_task release_task].freeze
  REVIEW_CALLS = %w[heartbeat_review release_review acknowledge_review_briefing give_verdict].freeze
  CLAIMS = { "builder" => "claim_next_task", "reviewer" => "claim_next_review" }.freeze
  READS = { "get_task_briefing" => :task, "get_review_briefing" => :review }.freeze

  # Ranked no lower than forbidden in L548's order.
  HOLDER_CAUSES = %w[lease_expired task_cancelled not_holder forbidden].freeze

  setup do
    @scenario = Scenario.new
    @builder = @scenario.seat(role: "builder", credential: @scenario.credential)
    @reviewer = @scenario.seat(role: "reviewer", credential: @scenario.credential(provider: "codex"))
  end

  test "every served agent operation is in the Roles table, and each role's served calls are covered here" do
    SERVED_AGENT.each do |operation_id|
      assert(%w[builder reviewer].any? { |role| ROLES.fetch(role).include?(operation_id) }, operation_id)
    end
    covered = TASK_CALLS + REVIEW_CALLS + CLAIMS.values + READS.keys + %w[get_next get_command]
    assert_equal SERVED_AGENT.sort, covered.sort
    TASK_CALLS.each { |operation_id| refute_includes ROLES.fetch("reviewer"), operation_id }
    REVIEW_CALLS.each { |operation_id| refute_includes ROLES.fetch("builder"), operation_id }
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

  test "Connect offers builder and reviewer only: a planner or an orchestrator seat is 422 and nothing is written" do
    %w[planner orchestrator].each do |role|
      before = counts
      call("connect_seat", token: @scenario.owner_token, key: new_key,
        body: { "name" => "Made-up #{role}", "role" => role, "provider" => "codex" })
      assert_response :unprocessable_entity
      assert_response_matches_contract
      assert_equal before, counts
    end
  end

  private

  def token(seat) = @scenario.token_for(seat)

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

  def task_body(operation_id, task)
    case operation_id
    when "acknowledge_task_briefing" then { "briefing_hash" => Leverage::Briefing.hash_for(task, @builder) }
    when "pass_criterion" then { "evidence" => { "kind" => "link", "value" => "https://example.test/made-up" } }
    when "submit_task" then { "handoff_note" => "Made-up note.", "work_reference" => "~/work/made-up" }
    when "release_task" then { "reason" => "unable_to_continue" }
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
