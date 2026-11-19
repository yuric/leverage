require "test_helper"

# Leverage::Tokens (milestone 2 plan IN-18): a prefix and 32 random bytes
# in URL-safe base64; the server keeps only the SHA-256 hex and finds the
# caller by it, for the kind the call expects.
class TokensTest < ActiveSupport::TestCase
  K = Leverage::Tokens

  setup { @scenario = Scenario.new }

  test "a token is its kind's prefix and 43 URL-safe characters" do
    { seat: "lvs_", helper: "lvh_", owner: "lvo_" }.each do |kind, prefix|
      token = K.issue(kind)
      assert_match(/\A#{prefix}[A-Za-z0-9_-]{43}\z/, token)
      assert_equal kind, K.kind_of(token)
    end
    refute_equal K.issue(:seat), K.issue(:seat)
    assert_raises(ArgumentError) { K.issue(:made_up) }
  end

  test "the digest is SHA-256 hex, and nothing else of the token is kept" do
    token = K.issue(:seat)
    assert_equal Digest::SHA256.hexdigest(token), K.digest(token)
  end

  test "a seat, a helper and an owner session are found by their own kind of token" do
    seat = @scenario.seat
    session = @scenario.owner_session
    helper = @scenario.helper

    found = K.find(@scenario.token_for(seat), kind: :seat)
    assert_equal [ "seat", seat.id, @scenario.workspace_id, seat ], found.to_h.values_at(:kind, :id, :workspace_id, :record)
    owner = K.find(@scenario.token_for(session), kind: :owner)
    assert_equal [ "owner", session.user_id, session ], owner.to_h.values_at(:kind, :id, :record)
    assert_equal [ "helper", helper.id ], K.find(@scenario.token_for(helper), kind: :helper).to_h.values_at(:kind, :id)
  end

  test "a token of another kind, an unknown token or nothing finds no caller" do
    seat = @scenario.seat
    helper = @scenario.helper

    assert_nil K.find(@scenario.token_for(helper), kind: :seat)
    assert_nil K.find(@scenario.token_for(seat), kind: :helper)
    assert_nil K.find(K.issue(:seat), kind: :seat)
    assert_nil K.find(nil, kind: :seat)
    assert_nil K.find("", kind: :owner)
    assert_nil K.find("lvs_short", kind: :seat)
  end

  test "an ended or removed seat's token finds nothing, and a deleted session's neither" do
    ended = @scenario.seat
    removed = @scenario.seat
    session = @scenario.owner_session
    tokens = [ ended, removed, session ].map { |record| @scenario.token_for(record) }
    @scenario.end_token(ended)
    @scenario.remove(removed)
    @scenario.end_token(session)

    assert_nil K.find(tokens[0], kind: :seat)
    assert_nil K.find(tokens[1], kind: :seat)
    assert_nil K.find(tokens[2], kind: :owner)
  end
end
