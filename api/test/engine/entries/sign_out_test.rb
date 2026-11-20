require "test_helper"

# Entries::SignOut (milestone 2 plan IN-5, IN-9): deletes the session the
# bearer token named, so the token answers 401 from then on, and stores a
# commands row like any mutating call. No event.
class SignOutTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @session = @scenario.owner_session
    @token = @scenario.token_for(@session)
  end

  def request(key: "sign-out-1", session: @session)
    T::Request.new(command: "sign_out", workspace_id: @scenario.workspace_id, caller_kind: "owner",
      caller_id: session.user_id, key: key, request_hash: "f" * 64, params: { "session_id" => session.id })
  end

  test "it deletes the session, so its token no longer signs in" do
    assert Leverage::Tokens.find(@token, kind: :owner)
    events = Event.count

    outcome = T.apply(request)

    assert outcome.completed?
    assert_nil outcome.once
    refute Session.exists?(@session.id)
    assert_nil Leverage::Tokens.find(@token, kind: :owner)
    assert_equal events, Event.count
    row = Command.find_by!(key: "sign-out-1")
    assert_equal [ "owner", @session.user_id, "sign_out", "completed" ], [ row.caller_kind, row.caller_id, row.command, row.outcome ]
  end

  test "another session of the owner goes on" do
    other = @scenario.owner_session
    T.apply(request)

    assert Leverage::Tokens.find(@scenario.token_for(other), kind: :owner)
  end

  test "a session that is already gone is SessionEnded and writes nothing" do
    T.apply(request)
    commands = Command.count

    assert_raises(T::Entries::SignOut::SessionEnded) { T.apply(request(key: "sign-out-2")) }
    assert_equal commands, Command.count
  end

  test "a session of another owner is never deleted" do
    stranger = Scenario.new.owner_session
    forged = T::Request.new(command: "sign_out", workspace_id: @scenario.workspace_id, caller_kind: "owner",
      caller_id: @session.user_id, key: "sign-out-3", request_hash: "f" * 64, params: { "session_id" => stranger.id })

    assert_raises(T::Entries::SignOut::SessionEnded) { T.apply(forged) }
    assert Session.exists?(stranger.id)
  end
end
