require "test_helper"
require_relative "accounts_support"

# connect_seat (PRD L590-L591, L803; milestone 2 plan §2.1, IN-11, IN-29,
# IN-30, SC-10, SC-11): writes seat.connected. A seat that connects on its
# own gets its token once; a seat the app runs gets a login whose checks
# have passed, no token (seat_token null), and is started: wanted running,
# with a start_seat request queued.
class ConnectSeatTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  def body(**fields)
    { "name" => "Made-up builder", "role" => "builder", "provider" => nil, "model" => nil, "effort" => nil,
      "strength_rank" => nil, "credential_id" => nil }.merge(fields.transform_keys(&:to_s))
  end

  test "a seat that connects on its own gets its token once, stored only as a digest" do
    key = new_key
    written = events_written { @outcome = assert_completed(owner_command("connect_seat", body(provider: "codex"), key: key)) }

    token = @outcome.once.fetch("seat_token")
    assert_match Leverage::Tokens::FORM, token
    assert token.start_with?("lvs_")
    seat = Seat.find(@outcome.result.fetch("seat_id"))
    assert_equal seat.id, Leverage::Tokens.find(token, kind: :seat).id
    assert_equal [ "Made-up builder", "builder", "codex", "", "", 1, nil, nil, false ],
      [ seat.name, seat.role, seat.provider, seat.model, seat.effort, seat.strength_rank, seat.credential_id, seat.run_state,
        seat.wanted_running ]
    assert_equal [ "seat.connected" ], written.map(&:type)
    assert_equal [ "seat", seat.id, "owner", @scenario.owner.id, key, {} ],
      [ written.first.subject_kind, written.first.subject_id, written.first.actor_kind, written.first.actor_id,
        written.first.command_id, written.first.payload ]
    assert_equal 0, HelperRequest.where(seat_id: seat.id).count
    assert_equal [ "seat_id" ], @outcome.result.keys
    assert_not_includes Command.find_by!(key: key).attributes.to_json, token
  end

  test "a repeat of the key answers the seat with no token and issues none" do
    key = new_key
    first = assert_completed(owner_command("connect_seat", body(provider: "codex"), key: key))
    digest = Seat.find(first.result.fetch("seat_id")).token_hash

    repeat = assert_completed(owner_command("connect_seat", body(provider: "codex"), key: key))

    assert_nil repeat.once
    assert_equal first.result, repeat.result
    assert_equal digest, Seat.find(first.result.fetch("seat_id")).token_hash
    assert_equal 1, Seat.where(workspace_id: @scenario.workspace_id, name: "Made-up builder").count
  end

  test "a seat the app runs takes its provider from its login, gets no token and is started" do
    credential = @scenario.credential(provider: "codex")
    written = events_written do
      @outcome = assert_completed(owner_command("connect_seat",
        body(role: "reviewer", name: "Made-up reviewer", credential_id: credential.id, model: "made-up-model", effort: nil)))
    end

    assert_equal({ "seat_token" => nil }, @outcome.once, "SeatConnected with seat_token null (§2.1)")
    seat = Seat.find(@outcome.result.fetch("seat_id"))
    assert_equal [ "codex", credential.id, "made-up-model", "", nil, "stopped", true ],
      [ seat.provider, seat.credential_id, seat.model, seat.effort, seat.token_hash, seat.run_state, seat.wanted_running ]
    assert_equal [ "seat.connected" ], written.map(&:type)
    start = HelperRequest.find_by!(seat_id: seat.id)
    assert_equal [ "start_seat", "queued", credential.id ], [ start.kind, start.state, start.credential_id ]
    assert_equal({ "role" => "reviewer", "provider" => "codex", "model" => "made-up-model", "effort" => nil }, start.params)
    assert_not_includes start.attributes.to_json, "Made-up reviewer"
  end

  test "a login whose add still runs cannot be given to a seat" do
    credential = @scenario.credential(added: false)

    assert_raises(T::NotFound) { owner_command("connect_seat", body(credential_id: credential.id)) }
  end

  test "an unknown login is not found" do
    assert_raises(T::NotFound) { owner_command("connect_seat", body(credential_id: SecureRandom.uuid)) }
  end

  test "a provider other than the login's is invalid" do
    credential = @scenario.credential(provider: "codex")

    assert_raises(T::Invalid) { owner_command("connect_seat", body(credential_id: credential.id, provider: "claude")) }
  end

  test "the login's own provider may be named" do
    credential = @scenario.credential(provider: "codex")

    assert_completed(owner_command("connect_seat", body(credential_id: credential.id, provider: "codex")))
  end

  test "a seat that connects on its own must name its provider" do
    assert_raises(T::Invalid) { owner_command("connect_seat", body) }
  end

  test "Connect offers builder and reviewer only in this milestone" do
    %w[planner orchestrator].each do |role|
      assert_raises(T::Invalid) { owner_command("connect_seat", body(role: role, provider: "codex")) }
    end
  end

  test "a strength rank sent is kept" do
    outcome = assert_completed(owner_command("connect_seat", body(provider: "grok", strength_rank: 3)))

    assert_equal 3, Seat.find(outcome.result.fetch("seat_id")).strength_rank
  end
end
