require "test_helper"

# The three authentication concerns (milestone 2 plan IN-18, IN-13), proven
# through controllers defined here: a bearer token goes to its digest, the
# digest to a row of the expected kind, or the call is 401 unauthenticated
# before anything else runs. A missing, unknown, ended or other kind's
# token is 401.
class AuthenticationTest < ActionDispatch::IntegrationTest
  include OpenapiAssertions

  class SeatController < ApplicationController
    include AuthenticatesSeat

    def show = render(json: { kind: current_caller.kind, id: current_caller.id, seat: current_seat.id })
  end

  class OwnerController < ApplicationController
    include AuthenticatesOwner

    def show = render(json: { kind: current_caller.kind, id: current_caller.id, session: current_session.id })
  end

  class HelperController < ApplicationController
    include AuthenticatesHelper

    def show = render(json: { kind: current_caller.kind, id: current_caller.id, helper: current_helper.id })
  end

  setup do
    @scenario = Scenario.new
    @seat = @scenario.seat
    @session = @scenario.owner_session
    @helper = @scenario.helper
  end

  def with_test_routes(&block)
    with_routing do |routes|
      routes.draw do
        get "seat", to: "authentication_test/seat#show"
        get "owner", to: "authentication_test/owner#show"
        get "helper", to: "authentication_test/helper#show"
      end
      block.call
    end
  end

  def call(path, token, scheme: "Bearer")
    headers = token.nil? ? {} : { "Authorization" => "#{scheme} #{token}" }
    get path, headers: headers
  end

  def assert_unauthenticated
    assert_response :unauthorized
    assert_equal "unauthenticated", response.parsed_body.dig("error", "code")
    assert_matches_component("TransportError", response.parsed_body)
  end

  test "each kind of token lets its own caller in" do
    with_test_routes do
      call("/seat", @scenario.token_for(@seat))
      assert_response :ok
      assert_equal({ "kind" => "seat", "id" => @seat.id, "seat" => @seat.id }, response.parsed_body)

      call("/owner", @scenario.token_for(@session))
      assert_response :ok
      assert_equal({ "kind" => "owner", "id" => @session.user_id, "session" => @session.id }, response.parsed_body)

      call("/helper", @scenario.token_for(@helper))
      assert_response :ok
      assert_equal({ "kind" => "helper", "id" => @helper.id, "helper" => @helper.id }, response.parsed_body)
    end
  end

  test "a missing token, another scheme or an empty bearer is 401" do
    with_test_routes do
      %w[/seat /owner /helper].each do |path|
        call(path, nil)
        assert_unauthenticated
        call(path, "", scheme: "Bearer")
        assert_unauthenticated
      end
      call("/seat", @scenario.token_for(@seat), scheme: "Basic")
      assert_unauthenticated
    end
  end

  test "an unknown token is 401" do
    with_test_routes do
      call("/seat", Leverage::Tokens.issue(:seat))
      assert_unauthenticated
      call("/owner", Leverage::Tokens.issue(:owner))
      assert_unauthenticated
      call("/helper", "lvh_made-up")
      assert_unauthenticated
    end
  end

  test "another kind's token is 401" do
    with_test_routes do
      call("/seat", @scenario.token_for(@helper))
      assert_unauthenticated
      call("/owner", @scenario.token_for(@seat))
      assert_unauthenticated
      call("/helper", @scenario.token_for(@session))
      assert_unauthenticated
    end
  end

  test "an ended token, a removed seat's token and a signed-out session are 401" do
    removed = @scenario.seat
    tokens = { seat: @scenario.token_for(@seat), removed: @scenario.token_for(removed),
               session: @scenario.token_for(@session), helper: @scenario.token_for(@helper) }
    @scenario.end_token(@seat)
    @scenario.remove(removed)
    @scenario.end_token(@session)
    @scenario.end_token(@helper)

    with_test_routes do
      call("/seat", tokens[:seat])
      assert_unauthenticated
      call("/seat", tokens[:removed])
      assert_unauthenticated
      call("/owner", tokens[:session])
      assert_unauthenticated
      call("/helper", tokens[:helper])
      assert_unauthenticated
    end
  end
end
