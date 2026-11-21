require "test_helper"
require_relative "../support/http_calls"

# Each caller's token opens only its own interface (PRD L823, L918;
# milestone 2 plan IN-13, IN-18, WP17): for every served operation, read
# from Http::RouteTable and the registry, a seat's token, the owner's
# session token and the helper's token are each sent in turn. The caller
# the registry names gets past sign-in; every other token, and no token at
# all, answers 401 unauthenticated before anything else is looked at, and
# writes nothing. The public operations need no token.
class CallerInterfacesTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions
  include HttpCalls

  # The interface each registry caller belongs to. The agent callers are
  # the seat roles' (roles.json); public needs no token.
  INTERFACES = {
    "any" => :seat, "builder" => :seat, "holder" => :seat, "reviewer" => :seat, "job_claimer" => :seat,
    "job_holder" => :seat, "owner" => :owner, "helper" => :helper, "public" => :public
  }.freeze

  # Sign-in itself: the owner's caller, but it proves who asks with the
  # password in its body (IN-9), not with a token.
  SIGN_IN = "sign_in_owner".freeze

  # Made-up values for the path parameters: ids that name nothing, a key,
  # a provider. A call that gets past sign-in may then answer 404.
  IDS = { "id" => "00000000-0000-4000-8000-00000000c0de", "cid" => "00000000-0000-4000-8000-00000000c0df",
          "aid" => "00000000-0000-4000-8000-00000000c0e0", "qid" => "00000000-0000-4000-8000-00000000c0e1",
          "key" => "made-up-key", "provider" => "claude" }.freeze

  SERVED = HttpCalls.served.map { |op| op.fetch("operation_id") }.freeze

  def self.interface(operation_id) = INTERFACES.fetch(HttpCalls.operation(operation_id).fetch("caller"))

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(role: "builder")
    @tokens = { seat: @scenario.token_for(@seat), owner: @scenario.owner_token, helper: @scenario.helper_token }
  end

  test "every served operation's caller belongs to one interface" do
    SERVED.each { |operation_id| assert self.class.interface(operation_id), operation_id }
    assert_equal %w[create_owner get_health get_setup_state],
      SERVED.select { |operation_id| self.class.interface(operation_id) == :public }.sort
  end

  test "the three tokens are told apart by their prefix and none signs in as another kind" do
    assert_match(/\Alvs_/, @tokens.fetch(:seat))
    assert_match(/\Alvo_/, @tokens.fetch(:owner))
    assert_match(/\Alvh_/, @tokens.fetch(:helper))
  end

  (SERVED - [ SIGN_IN ]).each do |operation_id|
    interface = interface(operation_id)
    next if interface == :public

    test "#{operation_id}: only the #{interface}'s token gets past sign-in" do
      before = counts
      (%i[seat owner helper] - [ interface ]).each do |other|
        send_with(operation_id, @tokens.fetch(other))
        assert_unauthenticated(operation_id, "a #{other} token")
      end
      send_with(operation_id, nil)
      assert_unauthenticated(operation_id, "no token")
      send_with(operation_id, "#{@tokens.fetch(interface)}x")
      assert_unauthenticated(operation_id, "a token that is not one")
      assert_equal before, counts, "#{operation_id}: a call that failed sign-in wrote something"

      send_with(operation_id, @tokens.fetch(interface))
      refute_equal 401, response.status, "#{operation_id}: the #{interface}'s own token: #{response.body}"
    end
  end

  test "sign_in_owner takes no token: a password signs in, a token in place of one does not" do
    %i[seat owner helper].each do |kind|
      call(SIGN_IN, key: new_key, body: { "email_address" => @scenario.owner.email_address, "password" => @tokens.fetch(kind) })
      assert_unauthenticated(SIGN_IN, "a #{kind} token as the password")
    end
  end

  # EN-20: a session's last use is written at most every five minutes, by
  # the owner's own calls (Transitions::RecordPoll.session).
  test "an owner call records the session's last use, at most every five minutes" do
    session = Session.find_by!(token_hash: Leverage::Tokens.digest(@tokens.fetch(:owner)))
    assert_nil session.last_used_at
    call("list_seats", token: @tokens.fetch(:owner))
    assert_response :ok
    used = session.reload.last_used_at
    refute_nil used, "the first call records it"

    call("get_board", token: @tokens.fetch(:owner))
    assert_response :ok
    assert_equal used, session.reload.last_used_at, "not again within five minutes"

    session.update_columns(last_used_at: used - 301)
    call("get_board", token: @tokens.fetch(:owner))
    assert_operator session.reload.last_used_at, :>, used - 301
  end

  test "the public operations answer without a token" do
    call("get_health")
    assert_response :ok
    assert_response_matches_contract
    call("get_setup_state")
    assert_response :ok
    assert_response_matches_contract
  end

  private

  def counts = [ Event.count, Command.count, Session.count, HelperRequest.count ]

  # The operation with made-up ids, a key and an empty body where it takes
  # them, and no wait: what fails sign-in fails before any of it is read.
  def send_with(operation_id, token)
    op = HttpCalls.operation(operation_id)
    post = op.fetch("method") == "POST"
    query = { "wait" => 0 } if !post && %w[get_next get_helper_next get_helper_request list_events].include?(operation_id)
    call(operation_id, token: token, key: (new_key if post), ids: IDS, body: (post ? {} : nil), query: query,
      check_request: false)
  end

  def assert_unauthenticated(operation_id, what)
    assert_equal 401, response.status, "#{operation_id} with #{what}: #{response.body}"
    assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
    assert_response_matches_contract
  end
end
