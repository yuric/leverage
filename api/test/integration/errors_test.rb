require "test_helper"

class ErrorsTest < ActionDispatch::IntegrationTest
  # A stand-in controller that fails in the ways the tests need.
  class FailingController < ApplicationController
    def boom
      raise "secret detail that must not reach the client"
    end

    def missing
      params.require(:needed)
    end
  end

  test "an unknown path answers 404 with the JSON error shape" do
    get "/v1/no-such-thing"

    assert_response :not_found
    assert_equal "application/json", response.media_type
    error = response.parsed_body.fetch("error")
    assert_equal "not_found", error.fetch("code")
    assert_kind_of String, error.fetch("message")
    assert_not_empty error.fetch("message")
  end

  test "an unexpected error answers 500 without revealing its message" do
    with_failing_routes do
      get "/boom"

      assert_response :internal_server_error
      assert_equal "application/json", response.media_type
      assert_equal({ "error" => { "code" => "internal_server_error", "message" => "Internal Server Error" } },
                   response.parsed_body)
      assert_no_match(/secret detail/, response.body)
    end
  end

  test "a missing parameter answers 400 with the JSON error shape" do
    with_failing_routes do
      get "/missing"

      assert_response :bad_request
      assert_equal "bad_request", response.parsed_body.dig("error", "code")
    end
  end

  private

  def with_failing_routes(&block)
    with_routing do |routes|
      routes.draw do
        get "boom", to: "errors_test/failing#boom"
        get "missing", to: "errors_test/failing#missing"
      end
      block.call
    end
  end
end
