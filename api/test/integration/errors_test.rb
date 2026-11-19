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

  test "the root path answers 404 with the JSON error shape" do
    get "/"

    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_equal "not_found", response.parsed_body.dig("error", "code")
  end

  test "an error raised outside a controller gets the JSON error shape" do
    status, headers, body = call_exceptions_app(ActionController::BadRequest.new("Invalid path parameters"))

    assert_equal 400, status
    assert_match %r{\Aapplication/json}, headers["content-type"]
    assert_equal({ "error" => { "code" => "bad_request", "message" => "Invalid path parameters" } },
                 JSON.parse(body))
  end

  test "a malformed query string gets the JSON error shape" do
    status, _headers, body = call_exceptions_app(ActionController::BadRequest.new("Invalid query parameters"),
                                                 query: "a[]=1&a[b]=2")

    assert_equal 400, status
    assert_equal "bad_request", JSON.parse(body).dig("error", "code")
  end

  test "an unexpected error outside a controller hides its message" do
    status, _headers, body = call_exceptions_app(RuntimeError.new("secret detail from a middleware"))

    assert_equal 500, status
    assert_equal({ "error" => { "code" => "internal_server_error", "message" => "Internal Server Error" } },
                 JSON.parse(body))
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

  # Calls the exceptions app the way ActionDispatch::ShowExceptions does when
  # a middleware, or the router, raises before any controller runs.
  def call_exceptions_app(exception, query: "")
    status = ActionDispatch::ExceptionWrapper.status_code_for_exception(exception.class.name)
    env = Rack::MockRequest.env_for("/#{status}?#{query}", "HTTP_ACCEPT" => "text/html")
    env["action_dispatch.exception"] = exception
    env["action_dispatch.original_path"] = "/somewhere"
    env["action_dispatch.original_request_method"] = "GET"
    status, headers, body = Rails.application.config.exceptions_app.call(env)
    text = +""
    body.each { |chunk| text << chunk }
    [ status, headers, text ]
  end

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
