require "test_helper"
require "open3"

# Host authorization (PRD, Security; ADR 0006): the API answers only a
# request addressed to this Mac's loopback (127.0.0.1, localhost, [::1]).
# A web page that rebinds its own name to 127.0.0.1 sends its own name as
# Host and is refused 403 before any controller runs, so it can neither
# create the owner's sign-in nor try a password. The compose service name
# api is refused like any other name: the network's resolver answers a
# single-label name, not this Mac, so whoever controls that resolver could
# serve a page from http://api:3000 and then point api at loopback. /up,
# the compose health check, is answered whatever the Host.
#
# The setting is production's (config/environments/production.rb), so the
# test boots the app in production in a child process and sends requests
# straight to it, with no server and no database. Each request carries its
# Host header, as a client's does: Rack::MockRequest sets none, and host
# authorization refuses a request without one whatever config.hosts says.
class HostAuthorizationTest < ActiveSupport::TestCase
  SCRIPT = <<~RUBY.freeze
    statuses = ARGV.each_slice(3).map do |method, host, path|
      env = Rack::MockRequest.env_for("http://\#{host}\#{path}", method: method, input: "{}",
        "HTTP_HOST" => host, "CONTENT_TYPE" => "application/json", "HTTP_IDEMPOTENCY_KEY" => "key-host")
      Rails.application.call(env).first
    end
    puts "STATUSES=\#{statuses.join(",")}"
  RUBY

  def statuses(requests)
    environment = { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "RAILS_FORCE_SSL" => "false",
                    "RAILS_ASSUME_SSL" => "false", "RAILS_LOG_LEVEL" => "fatal" }
    output, status = Open3.capture2e(environment, "bin/rails", "runner", SCRIPT, *requests.flatten,
      chdir: Rails.root.to_s)
    assert status.success?, output
    line = output.lines.find { |text| text.start_with?("STATUSES=") }
    assert line, output
    line.delete_prefix("STATUSES=").strip.split(",").map(&:to_i)
  end

  # The allowed hosts are sent to /v1/health, a path host authorization
  # checks: /up is excluded from it, so a 200 there proves nothing about
  # config.hosts. One /up case with a foreign host covers the exclusion.
  test "a request addressed to another host is refused 403; this Mac's loopback and /up are answered" do
    refused = [
      [ "POST", "attacker.example", "/v1/owner/setup" ],
      [ "POST", "attacker.example:3000", "/v1/owner/session" ],
      [ "GET", "rebound.example.test", "/v1/health" ],
      [ "GET", "127.0.0.1.", "/v1/health" ],
      [ "GET", "api:3000", "/v1/health" ],
      [ "GET", "api", "/v1/health" ],
      [ "POST", "api:3000", "/v1/owner/setup" ],
      [ "POST", "api:3000", "/v1/owner/session" ],
      [ "GET", "[0:0:0:0:0:0:0:1]:3000", "/v1/health" ]
    ]
    answered = [
      [ "GET", "127.0.0.1:3000", "/v1/health" ],
      [ "GET", "localhost:3000", "/v1/health" ],
      [ "GET", "[::1]:3000", "/v1/health" ],
      [ "GET", "attacker.example", "/up" ]
    ]
    got = statuses(refused + answered)

    assert_equal [ 403 ] * refused.size, got.first(refused.size), refused.inspect
    assert_equal [ 200 ] * answered.size, got.last(answered.size), answered.inspect
  end
end
