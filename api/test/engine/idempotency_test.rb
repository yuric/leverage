require "test_helper"

# Leverage::Idempotency (PRD L220, L486, L818; milestone 2 plan IN-8, IN-9,
# IN-11): the key's form, the request hash, and the commands row a repeat
# is answered from. The HTTP half (test 5) is test/interfaces/idempotency_test.rb.
class IdempotencyTest < ActiveSupport::TestCase
  I = Leverage::Idempotency
  T = Leverage::Transitions

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat
  end

  def request(key: "key-1", hash: "a" * 64, caller_id: @seat.id, command: "claim")
    T::Request.new(command: command, workspace_id: @scenario.workspace_id, caller_kind: "seat", caller_id: caller_id,
      key: key, request_hash: hash, params: {})
  end

  def store(request, outcome)
    ctx = @scenario.context(request: request)
    I.store(ctx, request, outcome)
  end

  test "a key is 1 to 128 characters of letters, digits, hyphens and underscores" do
    [ "a", "A-z_0-9", "x" * 128, SecureRandom.uuid ].each { |key| assert I.valid_key?(key), key }
    [ nil, "", "x" * 129, "has space", "dot.ted", "slash/", "é" ].each { |key| refute I.valid_key?(key), key.inspect }
  end

  test "the request hash is SHA-256 over the method, the path and the raw body" do
    hash = I.request_hash(method: "POST", path: "/v1/owner/tasks", body: '{"budget_cap":1.10}')

    assert_equal Digest::SHA256.hexdigest("POST\n/v1/owner/tasks\n{\"budget_cap\":1.10}"), hash
    refute_equal hash, I.request_hash(method: "POST", path: "/v1/owner/tasks", body: '{"budget_cap":1.1}')
    refute_equal hash, I.request_hash(method: "POST", path: "/v1/owner/tasks/x", body: '{"budget_cap":1.10}')
    refute_equal hash, I.request_hash(method: "PUT", path: "/v1/owner/tasks", body: '{"budget_cap":1.10}')
  end

  test "a hash without the password is the same for bodies that differ only in it" do
    one = I.request_hash(method: "POST", path: "/v1/owner/session", without: [ "password" ],
      body: '{"email_address":"owner@example.test","password":"made-up-1"}')
    two = I.request_hash(method: "POST", path: "/v1/owner/session", without: [ "password" ],
      body: '{"email_address":"owner@example.test","password":"made-up-2"}')
    other = I.request_hash(method: "POST", path: "/v1/owner/session", without: [ "password" ],
      body: '{"email_address":"other@example.test","password":"made-up-1"}')

    assert_equal one, two
    refute_equal one, other
  end

  test "a stored outcome is found again for the same key and hash" do
    outcome = T::Outcome.completed({ "task_id" => SecureRandom.uuid })
    store(request, outcome)

    found = I.find(request)
    assert_equal [ :completed, outcome.result, nil, nil ], [ found.outcome, found.result, found.refusal, found.once ]
  end

  test "the same key with another hash raises KeyReused" do
    store(request, T::Outcome.completed({}))

    assert_raises(I::KeyReused) { I.find(request(hash: "b" * 64)) }
  end

  test "a key belongs to its caller: another seat's same key is a new command" do
    store(request, T::Outcome.completed({}))

    assert_nil I.find(request(caller_id: @scenario.seat.id))
    assert_nil I.find(request(key: "key-2"))
  end

  test "a refusal is stored with its cause and read back as a Refusal" do
    store(request, T::Outcome.refused(T::Refusal.new(code: "not_holder")))
    row = Command.find_by!(key: "key-1")

    assert_equal [ "refused", { "code" => "not_holder", "rule_id" => nil, "reason" => nil }, nil ],
      [ row.outcome, row.refusal, row.result ]
    assert_equal T::Refusal.new(code: "not_holder", rule_id: nil, reason: nil), I.find(request).refusal
  end

  test "a value shown once is never stored" do
    store(request(command: "issue_seat_token"),
      T::Outcome.completed({ "seat_id" => @seat.id }, once: { "seat_token" => "lvs_made-up" }))

    assert_equal({ "seat_id" => @seat.id }, Command.find_by!(key: "key-1").result)
    assert_nil I.find(request(command: "issue_seat_token")).once
  end
end
