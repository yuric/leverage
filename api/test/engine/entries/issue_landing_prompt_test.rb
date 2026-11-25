require "test_helper"
require_relative "accounts_support"

class IssueLandingPromptTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  test "rotates the token and stores only its hash and the token-free receipt" do
    seat = own_seat
    previous = scenario.token_for(seat)
    key = new_key
    first = assert_completed(issue(seat, key: key))
    token = first.once.fetch("seat_token")

    assert_match Leverage::Tokens::FORM, token
    refute_equal previous, token
    assert_nil Leverage::Tokens.find(previous, kind: :seat)
    assert_equal seat.id, Leverage::Tokens.find(token, kind: :seat).id
    assert_equal Leverage::Tokens.digest(token), seat.reload.token_hash
    assert_equal({ "seat_id" => seat.id, "connection" => "http" }, first.result)
    assert_equal first.result, Command.find_by!(key: key).result

    repeated = assert_completed(issue(seat, key: key))
    assert_equal first.result, repeated.result
    assert_nil repeated.once
    assert_equal Leverage::Tokens.digest(token), seat.reload.token_hash
  end

  test "does not issue a prompt for an app-run seat or a removed seat" do
    native = running_seat
    original = native.token_hash
    assert_refused("invalid_state", issue(native))
    assert_equal original, native.reload.token_hash

    removed = own_seat
    scenario.remove(removed)
    assert_raises(T::NotFound) { issue(removed) }
  end

  test "two fresh keys before landing issue different tokens and release nothing" do
    seat = own_seat
    tokens = []
    events = events_written do
      2.times { tokens << assert_completed(issue(seat)).once.fetch("seat_token") }
    end

    assert_empty events
    refute_equal tokens.first, tokens.last
    assert_nil Leverage::Tokens.find(tokens.first, kind: :seat)
    assert_equal seat.id, Leverage::Tokens.find(tokens.last, kind: :seat).id
  end

  test "after polling or receiving work the seat cannot receive a new prompt" do
    polled = own_seat
    polled.update!(last_polled_at: scenario.database_now)
    builder = own_seat
    task = scenario.task(state: "working", builder: builder)
    reviewer = own_seat(role: "reviewer")
    review = scenario.review(scenario.task(state: "in_review"), reviewer: reviewer)
    checker = own_seat(role: "orchestrator")
    scenario.rule_check(scenario.task(state: "ready"), rule: scenario.rule(hook: "task.before_claim"),
      started: true, checker: checker)
    job = Job.find_by!(claimed_by_seat_id: checker.id)

    [ polled, builder, reviewer, checker ].each do |seat|
      original = seat.token_hash
      assert_empty events_written { assert_refused("invalid_state", issue(seat)) }
      assert_equal original, seat.reload.token_hash
    end
    assert_equal [ "working", builder.id ], task.reload.values_at(:state, :holder_seat_id)
    assert_equal reviewer.id, review.reload.reviewer_seat_id
    assert_equal "claimed", job.reload.state
  end

  private

  def issue(seat, key: new_key)
    assert T::Table.include?("issue_landing_prompt"), "the transition table does not serve prompt issuance"
    owner_command("issue_landing_prompt", { "id" => seat.id, "connection" => "http", "address" => "http://example.test" }, key: key)
  end
end
