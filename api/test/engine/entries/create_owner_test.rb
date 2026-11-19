require "test_helper"

# Entries::CreateOwner (milestone 2 plan IN-2, IN-4, IN-9, IN-11, EN-4): the
# first sign-in. In one transaction it creates the workspace with its
# default settings and no rule, the one owner with a bcrypt digest of the
# password, and a session whose token is returned once and stored only as
# a digest. Allowed once: a new key once an owner exists is 404.
class CreateOwnerTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  PASSWORD = "made-up-password-1".freeze
  EMAIL = "owner@example.test".freeze

  # Committed tests of other files may have left an owner in this worker's
  # database; inside this test's transaction there is none.
  setup do
    Session.delete_all
    User.delete_all
  end

  def request(key: "setup-1", email: EMAIL, password: PASSWORD, caller_id: nil)
    T::Request.new(command: "create_owner", workspace_id: nil, caller_kind: "owner", caller_id: caller_id, key: key,
      request_hash: Digest::SHA256.hexdigest("setup #{email}"), params: { "email_address" => email, "password" => password })
  end

  test "it creates the workspace, the owner and a session, and returns the token once" do
    counts = [ Workspace.count, Event.count, Rule.count ]
    outcome = T.apply(request)

    assert outcome.completed?
    user = User.find_by!(email_address: EMAIL)
    workspace = Workspace.find(user.workspace_id)
    assert_equal [ counts[0] + 1, counts[1], counts[2] ], [ Workspace.count, Event.count, Rule.count ],
      "one workspace, no event and no rule (EN-4)"
    assert_equal 3600, workspace.lease_length_seconds, "the workspace has the default settings"
    assert user.authenticate(PASSWORD), "the password is kept as a digest that authenticates"
    refute_includes user.password_digest, PASSWORD

    token = outcome.once.fetch("session_token")
    assert_match Leverage::Tokens::FORM, token
    assert token.start_with?("lvo_")
    session = Session.find_by!(user_id: user.id)
    assert_equal Leverage::Tokens.digest(token), session.token_hash
    assert_equal workspace.id, session.workspace_id
    assert_equal({ "user_id" => user.id, "created_at" => outcome.result.fetch("created_at") }, outcome.result)
    signed_in = Leverage::Tokens.find(token, kind: :owner)
    assert_equal [ "owner", user.id ], [ signed_in.kind, signed_in.id ]

    row = Command.find_by!(key: "setup-1")
    assert_equal [ workspace.id, "owner", user.id, "create_owner", "completed" ],
      [ row.workspace_id, row.caller_kind, row.caller_id, row.command, row.outcome ]
    assert_equal outcome.result, row.result
    refute_includes row.to_json, token
    refute_includes row.to_json, PASSWORD
  end

  test "a repeat of its key answers the stored outcome without the token and writes nothing" do
    first = T.apply(request)
    owner = User.find_by!(email_address: EMAIL)
    counts = [ Workspace.count, User.count, Session.count, Command.count ]

    repeat = T.apply(request(caller_id: owner.id))

    assert repeat.completed?
    assert_nil repeat.once
    assert_equal first.result, repeat.result
    assert_equal counts, [ Workspace.count, User.count, Session.count, Command.count ]
  end

  test "a new key once an owner exists is 404 and writes nothing" do
    T.apply(request)
    owner = User.find_by!(email_address: EMAIL)
    counts = [ Workspace.count, User.count, Session.count, Command.count ]

    assert_raises(T::NotFound) { T.apply(request(key: "setup-2", caller_id: owner.id)) }
    assert_raises(T::NotFound) { T.apply(request(key: "setup-3", email: "other@example.test")) }
    assert_equal counts, [ Workspace.count, User.count, Session.count, Command.count ]
  end

  test "an owner made any other way also closes setup" do
    Scenario.new.owner

    assert_raises(T::NotFound) { T.apply(request) }
  end

  test "a password shorter than 8 characters is invalid and writes nothing (IN-4)" do
    counts = [ Workspace.count, User.count, Session.count, Command.count ]

    assert_raises(T::Invalid) { T.apply(request(password: "short-7")) }
    assert_equal counts, [ Workspace.count, User.count, Session.count, Command.count ]
    assert T.apply(request(key: "setup-8", password: "exactly8")).completed?
  end
end
