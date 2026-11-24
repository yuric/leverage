require "test_helper"
require_relative "accounts_support"

# connect_seat (PRD L590-L591, L803; milestone 2 plan §2.1, IN-11, IN-29,
# IN-30, SC-10, SC-11): writes seat.connected. A seat that connects on its
# own gets its token from a separate landing prompt command. A seat the app
# runs gets a verified login and a queued start_seat request.
class ConnectSeatTest < ActiveSupport::TestCase
  include AccountsSupport

  setup { use_scenario }

  def body(**fields)
    { "name" => "Made-up builder", "role" => "builder", "provider" => nil, "model" => nil, "effort" => nil,
      "strength_rank" => nil, "credential_id" => nil }.merge(fields.transform_keys(&:to_s))
  end

  test "a seat that connects on its own has no token until the owner issues a prompt" do
    key = new_key
    written = events_written { @outcome = assert_completed(owner_command("connect_seat", body(provider: "codex"), key: key)) }

    assert_nil @outcome.once
    seat = Seat.find(@outcome.result.fetch("seat_id"))
    assert_nil seat.token_hash
    assert_equal [ "Made-up builder", "builder", "codex", "", "", 1, nil, nil, false ],
      [ seat.name, seat.role, seat.provider, seat.model, seat.effort, seat.strength_rank, seat.credential_id, seat.run_state,
        seat.wanted_running ]
    assert_equal [ "seat.connected" ], written.map(&:type)
    assert_equal [ "seat", seat.id, "owner", @scenario.owner.id, key, {} ],
      [ written.first.subject_kind, written.first.subject_id, written.first.actor_kind, written.first.actor_id,
        written.first.command_id, written.first.payload ]
    assert_equal 0, HelperRequest.where(seat_id: seat.id).count
    assert_equal [ "seat_id" ], @outcome.result.keys
    assert_equal @outcome.result, Command.find_by!(key: key).result
  end

  test "a repeat of the key answers the seat with no token and issues none" do
    key = new_key
    first = assert_completed(owner_command("connect_seat", body(provider: "codex"), key: key))
    digest = Seat.find(first.result.fetch("seat_id")).token_hash

    repeat = assert_completed(owner_command("connect_seat", body(provider: "codex"), key: key))

    assert_nil repeat.once
    assert_equal first.result, repeat.result
    assert_nil digest
    assert_nil Seat.find(first.result.fetch("seat_id")).token_hash
    assert_equal 1, Seat.where(workspace_id: @scenario.workspace_id, name: "Made-up builder").count
  end

  test "a seat the app runs takes its provider from its login, gets no token and is started" do
    credential = @scenario.credential(provider: "codex")
    written = events_written do
      @outcome = assert_completed(owner_command("connect_seat",
        body(role: "reviewer", name: "Made-up reviewer", credential_id: credential.id, model: "made-up-model", effort: nil)))
    end

    assert_nil @outcome.once
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

  test "an API token cannot be given to a seat, even when its add still runs" do
    [ @scenario.token_credential, @scenario.token_credential(added: false) ].each do |token|
      assert_raises(T::Invalid) { owner_command("connect_seat", body(credential_id: token.id)) }
    end

    assert_empty Seat.where(workspace_id: @scenario.workspace_id)
    assert_empty HelperRequest.where(workspace_id: @scenario.workspace_id)
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

  # Milestone 4 plan RV-5, §0.1 fact 12: the two job roles arrive. Any
  # login, with or without a model, and nothing refused for its provider;
  # milestone 2's "builder and reviewer only" is gone.
  test "a planner and an orchestrator connect like a builder: on any login, with or without a model" do
    logins = Leverage::Contract.registry.fetch("credential_providers").select { |entry| entry.fetch("kind") == "login" }
      .map { |entry| @scenario.credential(provider: entry.fetch("provider")) }
    %w[planner orchestrator].each do |role|
      logins.each do |login|
        provider = login.provider
        [ nil, "#{provider}-model-1" ].each do |model|
          outcome = assert_completed(owner_command("connect_seat", body(name: "Made-up #{role}", role: role,
            credential_id: login.id, model: model)))
          seat = Seat.find(outcome.result.fetch("seat_id"))
          assert_equal [ role, provider, model.to_s, login.id, true ],
            [ seat.role, seat.provider, seat.model, seat.credential_id, seat.wanted_running ]
          assert HelperRequest.exists?(seat_id: seat.id, kind: "start_seat")
        end
      end
      outcome = assert_completed(owner_command("connect_seat", body(role: role, provider: "gemini")))
      assert_nil outcome.once
      assert_nil Seat.find(outcome.result.fetch("seat_id")).token_hash
    end
  end

  test "a role the registry does not list is 422" do
    assert_raises(T::Invalid) { owner_command("connect_seat", body(role: "owner", provider: "codex")) }
  end

  test "a strength rank sent is kept" do
    outcome = assert_completed(owner_command("connect_seat", body(provider: "grok", strength_rank: 3)))

    assert_equal 3, Seat.find(outcome.result.fetch("seat_id")).strength_rank
  end

  test "a whole number written with a decimal point is an integer in the request schema" do
    outcome = assert_completed(owner_command("connect_seat", body(provider: "grok", strength_rank: 2.0)))

    assert_equal 2, Seat.find(outcome.result.fetch("seat_id")).strength_rank
  end

  test "connecting refuses ranks outside Standard, Stronger and Strongest" do
    assert_no_difference -> { Seat.where(workspace_id: @scenario.workspace_id).count } do
      [ 0, 4, 2.5, "2", false ].each do |rank|
        assert_raises(T::Invalid) { owner_command("connect_seat", body(provider: "grok", strength_rank: rank)) }
      end
    end
  end

  # Milestone 3 plan HD-1: Connect builds the start from SeatRuns.placement.
  test "a seat connected on a limited login starts on its first available login" do
    own = @scenario.credential
    below = @scenario.credential(provider: "codex")
    @scenario.limit_credential(own, reset_at: @scenario.database_now + 3600)

    outcome = assert_completed(owner_command("connect_seat", body(credential_id: own.id, model: "seat-model")))

    start = HelperRequest.find_by!(seat_id: outcome.result.fetch("seat_id"), kind: "start_seat")
    assert_equal below.id, start.credential_id
    assert_equal({ "role" => "builder", "provider" => "codex", "model" => nil, "effort" => nil }, start.params)
  end
end
