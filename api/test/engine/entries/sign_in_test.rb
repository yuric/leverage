require "test_helper"

# Entries::SignIn (milestone 2 plan IN-5, IN-9, IN-11, IN-18): a new session
# for the owner the controller has already checked the password of. The
# token is returned once and stored only as its digest; a repeat of the
# key answers the stored, token-free outcome and opens no second session.
class SignInTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @owner = @scenario.owner
  end

  def request(key: "sign-in-1", caller_id: @owner.id)
    T::Request.new(command: "sign_in", workspace_id: @scenario.workspace_id, caller_kind: "owner", caller_id: caller_id,
      key: key, request_hash: "e" * 64, params: { "email_address" => @owner.email_address })
  end

  test "it opens a session and returns its token once" do
    events = Event.count
    outcome = T.apply(request)

    assert outcome.completed?
    token = outcome.once.fetch("session_token")
    assert token.start_with?("lvo_")
    session = Session.find_by!(token_hash: Leverage::Tokens.digest(token))
    assert_equal [ @owner.id, @scenario.workspace_id ], [ session.user_id, session.workspace_id ]
    assert_equal({ "user_id" => @owner.id, "created_at" => outcome.result.fetch("created_at") }, outcome.result)
    assert_equal events, Event.count, "sign-in changes nothing in the log (IF-17)"

    row = Command.find_by!(key: "sign-in-1")
    assert_equal [ "owner", @owner.id, "sign_in" ], [ row.caller_kind, row.caller_id, row.command ]
    assert_equal outcome.result, row.result
    refute_includes row.to_json, token
  end

  test "a repeat of the key answers the stored outcome without a token or a second session" do
    first = T.apply(request)
    sessions = Session.count

    repeat = T.apply(request)

    assert_nil repeat.once
    assert_equal first.result, repeat.result
    assert_equal sessions, Session.count
  end

  test "each sign-in has a session of its own" do
    one = T.apply(request).once.fetch("session_token")
    two = T.apply(request(key: "sign-in-2")).once.fetch("session_token")

    refute_equal one, two
    assert Leverage::Tokens.find(one, kind: :owner), "an earlier session goes on until it is signed out (IN-5)"
    assert Leverage::Tokens.find(two, kind: :owner)
  end

  test "an owner that is not in the workspace is 404 and writes nothing" do
    other = Scenario.new.owner
    counts = [ Session.count, Command.count ]

    assert_raises(T::NotFound) { T.apply(request(caller_id: other.id)) }
    assert_raises(T::NotFound) { T.apply(request(key: "sign-in-3", caller_id: SecureRandom.uuid)) }
    assert_equal counts, [ Session.count, Command.count ]
  end
end
