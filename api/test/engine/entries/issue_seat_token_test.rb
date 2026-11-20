require "test_helper"

# Entries::IssueSeatToken (milestone 2 plan IN-11, IN-17, IN-18, PK-7): for a
# start_seat request the helper has, a fresh seat token, whose digest
# replaces the seat's token_hash, so the previous token ends. The token is
# returned once and never stored: not in the commands row, not in the
# helper request, never in an event.
class IssueSeatTokenTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @helper = @scenario.helper
    @seat = @scenario.seat(credential: @scenario.credential)
    @old_token = @scenario.token_for(@seat)
    @start = start_request(@seat)
  end

  def start_request(seat, kind: "start_seat", state: "picked_up", workspace_id: @scenario.workspace_id)
    HelperRequest.create!(workspace_id: workspace_id, kind: kind, seat_id: seat.id, state: state,
      requested_at: @scenario.database_now, params: { "role" => seat.role, "provider" => seat.provider })
  end

  def request(id: @start.id, key: "pickup-1")
    T::Request.new(command: "issue_seat_token", workspace_id: @scenario.workspace_id, caller_kind: "helper",
      caller_id: @helper.id, key: key, request_hash: "0" * 64, params: { "id" => id })
  end

  test "it issues a fresh token once, stores its digest and ends the previous one" do
    events = Event.count
    outcome = T.apply(request)

    assert outcome.completed?
    token = outcome.once.fetch("seat_token")
    assert_match Leverage::Tokens::FORM, token
    assert token.start_with?("lvs_")
    assert_equal({ "helper_request_id" => @start.id, "seat_id" => @seat.id }, outcome.result)
    assert_equal Leverage::Tokens.digest(token), @seat.reload.token_hash
    assert_equal @seat.id, Leverage::Tokens.find(token, kind: :seat).id
    assert_nil Leverage::Tokens.find(@old_token, kind: :seat), "the previous token ends at the next issue (IN-17)"
    assert_equal events, Event.count, "never in an event: none is written"

    row = Command.find_by!(key: "pickup-1")
    assert_equal [ "helper", @helper.id, "issue_seat_token" ], [ row.caller_kind, row.caller_id, row.command ]
    assert_equal outcome.result, row.result
    refute_includes row.to_json, token
    refute_includes @start.reload.to_json, token
  end

  test "a repeat of the key answers without the token and does not rotate it again" do
    token = T.apply(request).once.fetch("seat_token")
    digest = @seat.reload.token_hash

    repeat = T.apply(request)

    assert_nil repeat.once
    assert_equal({ "helper_request_id" => @start.id, "seat_id" => @seat.id }, repeat.result)
    assert_equal digest, @seat.reload.token_hash
    assert Leverage::Tokens.find(token, kind: :seat)
  end

  test "a new key rotates again" do
    one = T.apply(request).once.fetch("seat_token")
    two = T.apply(request(key: "pickup-2")).once.fetch("seat_token")

    refute_equal one, two
    assert_nil Leverage::Tokens.find(one, kind: :seat)
    assert Leverage::Tokens.find(two, kind: :seat)
  end

  test "an id that names no start_seat request of the helper's workspace is 404" do
    other = Scenario.new
    elsewhere = HelperRequest.create!(workspace_id: other.workspace_id, kind: "start_seat",
      seat_id: other.seat(credential: other.credential).id, state: "queued", requested_at: @scenario.database_now)
    stop = start_request(@seat, kind: "stop_seat")
    counts = [ Command.count, @seat.reload.token_hash ]

    [ SecureRandom.uuid, elsewhere.id, stop.id ].each_with_index do |id, index|
      assert_raises(T::NotFound) { T.apply(request(id: id, key: "pickup-404-#{index}")) }
    end
    assert_equal counts, [ Command.count, @seat.reload.token_hash ]
  end

  test "a removed seat or a finished request is refused invalid_state and keeps its token" do
    finished = start_request(@seat, state: "finished")
    failed = start_request(@seat, state: "failed")
    [ finished, failed ].each_with_index do |start, index|
      outcome = T.apply(request(id: start.id, key: "pickup-done-#{index}"))
      assert_equal [ :refused, "invalid_state", nil ], [ outcome.outcome, outcome.refusal.code, outcome.once ]
    end

    @scenario.remove(@seat)
    outcome = T.apply(request(key: "pickup-removed"))
    assert_equal [ :refused, "invalid_state", nil ], [ outcome.outcome, outcome.refusal.code, outcome.once ]
    assert_equal Leverage::Tokens.digest(@old_token), @seat.reload.token_hash
    assert_equal "refused", Command.find_by!(key: "pickup-removed").outcome
  end
end
