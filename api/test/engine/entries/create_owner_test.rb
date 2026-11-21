require "test_helper"

# Entries::CreateOwner (milestone 2 plan IN-2, IN-4, IN-9, IN-11; milestone
# 4 plan RD-1, RD-2): the first sign-in. In one transaction it creates the
# workspace with its default settings, the one owner with a bcrypt digest
# of the password, a session whose token is returned once and stored only
# as a digest, and the seven shipped rules, whose rule.created by the owner
# with the command's key are the workspace's first events (L434, SM-33;
# milestone 2's "no event and no rule", EN-4, is replaced by RD-2). Allowed
# once: a new key once an owner exists is 404.
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
    assert_equal [ counts[0] + 1, counts[1] + 7, counts[2] + 7 ], [ Workspace.count, Event.count, Rule.count ],
      "one workspace, its seven shipped rules and their seven events (L434, RD-1)"
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

  test "the workspace's first events are rule.created for each shipped rule, by the owner, with its key (L434, SM-33, RD-2)" do
    outcome = T.apply(request)

    user = User.find_by!(email_address: EMAIL)
    events = Event.where(workspace_id: user.workspace_id).order(:seq).to_a
    rules = Rule.where(workspace_id: user.workspace_id).to_a.index_by(&:id)
    shipped = Leverage::Rules::Shipped.all
    assert_equal [ "rule.created" ] * 7, events.map(&:type)
    assert_equal (1..7).to_a, events.map(&:seq), "nothing comes before them"
    assert_equal shipped.map(&:key), events.map { |event| rules.fetch(event.subject_id).key }
    events.each do |event|
      rule = rules.fetch(event.subject_id)
      version = RuleVersion.find_by!(rule_id: rule.id, version: 1)
      assert_equal({ "rule_version_id" => version.id, "version" => 1, "enabled" => true }, event.payload)
      assert_equal [ "owner", user.id, "setup-1", "rule", nil ],
        [ event.actor_kind, event.actor_id, event.command_id, event.subject_kind, event.task_id ]
      assert_equal [ true, 1 ], [ rule.enabled, rule.current_version ]
      assert_equal [ "shipped", "owner", user.id ], [ version.origin, version.author_kind, version.author_id ]
    end
    assert outcome.completed?
  end

  test "a password that is too short creates no rule either" do
    counts = [ Rule.count, RuleVersion.count, Event.count ]

    assert_raises(T::Invalid) { T.apply(request(password: "short-7")) }
    assert_equal counts, [ Rule.count, RuleVersion.count, Event.count ]
  end
end
