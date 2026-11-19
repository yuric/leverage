require "test_helper"

# A seat's sign-in (PRD L823; milestone 2 plan IN-17, IN-18, PK-7): the token
# the helper picks up through issue_seat_token signs the seat in, the
# previous one ends at that moment, and the token of a removed seat answers
# 401. The seat side is a controller defined here, because the agent
# controllers are another package's; the pickup is the real route.
class SeatAuthTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  class SeatController < ApplicationController
    include AuthenticatesSeat

    def show = render(json: { seat_id: current_seat.id })
  end

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat(credential: @scenario.credential)
    @start = HelperRequest.create!(workspace_id: @scenario.workspace_id, kind: "start_seat", seat_id: @seat.id,
      state: "picked_up", requested_at: @scenario.database_now, params: { "role" => "builder", "provider" => "claude" })
  end

  def pick_up(key: "pickup-#{SecureRandom.hex(4)}")
    post "/v1/helper/requests/#{@start.id}/seat-token",
      headers: { "Authorization" => "Bearer #{@scenario.helper_token}", "Idempotency-Key" => key }
    assert_response :ok
    assert_response_matches_contract
    response.parsed_body.dig("result", "seat_token")
  end

  def seat_call(token)
    with_routing do |routes|
      routes.draw { get "seat", to: "seat_auth_test/seat#show" }
      get "/seat", headers: token ? { "Authorization" => "Bearer #{token}" } : {}
      yield response
    end
  end

  def assert_signs_in(token)
    seat_call(token) do |answer|
      assert_equal 200, answer.status
      assert_equal({ "seat_id" => @seat.id }, answer.parsed_body)
    end
  end

  def assert_refused(token)
    seat_call(token) do |answer|
      assert_equal 401, answer.status
      assert_equal "unauthenticated", answer.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", answer.parsed_body)
    end
  end

  test "the picked-up token signs the seat in and ends the one before it" do
    connected = @scenario.token_for(@seat)
    assert_signs_in(connected)

    first = pick_up
    assert_signs_in(first)
    assert_refused(connected)

    second = pick_up
    assert_signs_in(second)
    assert_refused(first)
  end

  test "the token of a removed seat answers 401" do
    token = pick_up
    assert_signs_in(token)

    @scenario.remove(@seat)
    assert_refused(token)
  end

  test "an ended token, a token of another kind, or a made-up one answers 401" do
    token = pick_up
    @scenario.end_token(@seat)
    assert_refused(token)

    assert_refused(nil)
    assert_refused(@scenario.helper_token)
    assert_refused(@scenario.owner_token)
    assert_refused("lvs_#{"A" * 43}")
    assert_refused(token.sub("lvs_", "lvh_"))
  end

  test "a seat's token does not reach the owner's or the helper's calls" do
    token = pick_up
    post "/v1/helper/requests/#{@start.id}/seat-token", headers: { "Authorization" => "Bearer #{token}", "Idempotency-Key" => "k1" }
    assert_response :unauthorized
    post "/v1/owner/session/sign-out", headers: { "Authorization" => "Bearer #{token}", "Idempotency-Key" => "k2" }
    assert_response :unauthorized
  end
end
