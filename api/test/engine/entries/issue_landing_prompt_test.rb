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

  test "releases a Working task once and leaves work acquired after issuance alone" do
    seat = own_seat
    task = scenario.task(state: "working", builder: seat)
    key = new_key
    released = events_written { assert_completed(issue(seat, key: key)) }.find { |event| event.type == "task.released" }

    assert_equal [ "ready", nil ], task.reload.values_at(:state, :holder_seat_id)
    assert_equal [ task.id, "new_prompt" ], [ released.task_id, released.payload.fetch("reason") ]

    subsequent = scenario.task(state: "working", builder: seat)
    assert_empty events_written { assert_completed(issue(seat, key: key)) }
    assert_equal [ "working", seat.id ], subsequent.reload.values_at(:state, :holder_seat_id)
  end

  private

  def issue(seat, key: new_key)
    assert T::Table.include?("issue_landing_prompt"), "the transition table does not serve prompt issuance"
    owner_command("issue_landing_prompt", { "id" => seat.id, "connection" => "http", "address" => "http://example.test" }, key: key)
  end
end
