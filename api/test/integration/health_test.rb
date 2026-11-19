require "test_helper"

class HealthTest < ActionDispatch::IntegrationTest
  test "GET /v1/health answers ok with the app version" do
    get "/v1/health"

    assert_response :ok
    assert_equal "application/json", response.media_type
    assert_equal({ "status" => "ok", "version" => Leverage::VERSION }, response.parsed_body)
  end

  test "the app version is a semantic version string" do
    assert_match(/\A\d+\.\d+\.\d+\z/, Leverage::VERSION)
  end
end
