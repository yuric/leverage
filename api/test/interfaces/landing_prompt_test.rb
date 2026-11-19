require "test_helper"

# GET /v1/owner/seats/{id}/landing-prompt (the owner's issue 11, Q-15, MA-12;
# manager-overrides item 11): the text the owner pastes into an agent that
# connects on its own. It names every call the seat's role may make and that
# the server serves, and none it may not; it holds no token and nothing
# shaped like one; a seat the app runs is refused; and every answer is a
# LandingPrompt.
class LandingPromptTest < CommittingTestCase
  include ActionDispatch::IntegrationTest::Behavior
  include OpenapiAssertions

  TOKEN_SHAPE = /lv[sho]_[A-Za-z0-9_-]{6,}/

  setup do
    @token = scenario.owner_token
    @builder = scenario.seat(role: "builder", name: "Made-up builder agent")
    @reviewer = scenario.seat(role: "reviewer", name: "Made-up reviewer agent")
  end

  def prompt(seat, token: @token, host: nil)
    headers = { "Authorization" => ("Bearer #{token}" if token) }.compact
    headers["Host"] = host if host
    get "/v1/owner/seats/#{seat.respond_to?(:id) ? seat.id : seat}/landing-prompt", headers: headers
  end

  def text_for(seat)
    prompt(seat)
    assert_response :ok, response.body
    assert_response_matches_contract
    response.parsed_body.fetch("text")
  end

  def operations = Leverage::Contract.registry.fetch("operations").to_h { |operation| [ operation.fetch("operation_id"), operation ] }

  def role_operations(role)
    Leverage::Contract.roles.fetch("roles").find { |entry| entry.fetch("role") == role }.fetch("operations")
  end

  # The registry operations of a role that the server serves.
  def served(role) = role_operations(role).select { |id| Leverage::Http::RouteTable.serves?(id) }

  # An operation id on its own, not inside a longer name (get_task is an
  # owner call and also the start of get_task_briefing).
  def names_operation?(text, id) = text.match?(/(?<![a-z_])#{Regexp.escape(id)}(?![a-z_])/)

  # "METHOD /path" on its own, not as the start of a longer path.
  def names_call?(text, operation)
    text.match?(/#{operation.fetch("method")}\s+#{Regexp.escape(operation.fetch("path"))}(?![\w\/{}\-])/)
  end

  test "a builder's prompt names every served call a builder may make, by name, method and path" do
    text = text_for(@builder)

    ids = served("builder")
    assert_includes ids, "get_next"
    assert_includes ids, "claim_next_task"
    ids.each do |id|
      assert names_operation?(text, id), "the builder prompt must name #{id}"
      assert names_call?(text, operations.fetch(id)), "the builder prompt must give #{operations.fetch(id).values_at("method", "path").join(" ")}"
    end
  end

  test "a reviewer's prompt names every served call a reviewer may make, by name, method and path" do
    text = text_for(@reviewer)

    ids = served("reviewer")
    assert_includes ids, "claim_next_review"
    assert_includes ids, "give_verdict"
    ids.each do |id|
      assert names_operation?(text, id), "the reviewer prompt must name #{id}"
      assert names_call?(text, operations.fetch(id)), "the reviewer prompt must give #{operations.fetch(id).values_at("method", "path").join(" ")}"
    end
  end

  test "a prompt names no call its role may not make: no other role's, no owner's, no helper's, none the server does not serve" do
    { @builder => "builder", @reviewer => "reviewer" }.each do |seat, role|
      text = text_for(seat)
      allowed = served(role)
      (operations.keys - allowed).each do |id|
        refute names_operation?(text, id), "the #{role} prompt must not name #{id}"
        refute names_call?(text, operations.fetch(id)), "the #{role} prompt must not give #{operations.fetch(id).values_at("method", "path").join(" ")}"
      end
      (role_operations(role) - allowed).each do |id|
        refute names_operation?(text, id), "#{id} is not served yet, so the #{role} prompt leaves it out"
      end
      refute_match %r{/v1/owner|/v1/helper}, text
    end
  end

  test "the prompt tells the agent the server, its role and name, how it signs in and the three calls to start with" do
    text = text_for(@builder)

    assert_includes text, "http://www.example.com", "the address the request came in on"
    assert_includes text, "Made-up builder agent"
    assert_match(/builder/i, text)
    assert_includes text, "LEVERAGE_SEAT_TOKEN"
    assert_match(/Authorization: Bearer \$LEVERAGE_SEAT_TOKEN/, text)
    assert_match %r{curl[^\n]*http://www\.example\.com/v1/next}, text
    assert_match %r{curl[^\n]*-X POST[^\n]*http://www\.example\.com/v1/tasks/claim-next|curl[^\n]*http://www\.example\.com/v1/tasks/claim-next}, text
    assert_match(/Idempotency-Key/, text)

    reviewer_text = text_for(@reviewer)
    assert_match %r{http://www\.example\.com/v1/reviews/claim-next}, reviewer_text
    refute_includes reviewer_text, "/v1/tasks/claim-next"
  end

  test "the prompt uses the address the request came in on" do
    prompt(@builder, host: "127.0.0.1:41234")
    assert_response :ok
    assert_includes response.parsed_body["text"], "http://127.0.0.1:41234/v1/next"
    refute_includes response.parsed_body["text"], "www.example.com"
  end

  test "the prompt gives the workspace's lease length and the defaults the agent confirms with its user" do
    scenario.workspace.update!(lease_length_seconds: 600)
    text = text_for(@builder)

    assert_match(/10 minutes/, text)
    assert_equal 20, response.parsed_body["check_interval_minutes"]
    assert_match(/every 20 minutes/, text)
    assert_match(/one task at a time/i, text)
    assert_match(/release/i, text)
    assert_match(/role file/i, text)
    assert_match(/briefing/i, text)
    assert_match(/rules/i, text)
    assert_match(/ask (your|its) user/i, text)
    assert_match(/confirm/i, text)

    scenario.workspace.update!(lease_length_seconds: 3600)
    assert_match(/60 minutes/, text_for(@builder))
  end

  test "the prompt holds no token and nothing shaped like one" do
    token = scenario.token_for(@builder)
    digest = Leverage::Tokens.digest(token)
    [ @builder, @reviewer ].each do |seat|
      text = text_for(seat)
      refute_match TOKEN_SHAPE, text
      refute_includes text, token
      refute_includes text, digest
      refute_includes text, scenario.owner_token
      refute_includes text, scenario.token_for(seat)
      %w[lvs_ lvh_ lvo_].each { |prefix| refute_includes text, prefix }
    end
    assert_no_match TOKEN_SHAPE, response.body
  end

  test "a seat's own connect token never reaches the prompt even when the request carries it as an address" do
    # The text is built from the seat's row and the request's host, never from
    # a header an agent could put a token in.
    prompt(@builder, host: "127.0.0.1:41234")
    assert_response :ok
    refute_match TOKEN_SHAPE, response.parsed_body["text"]
  end

  test "an address that could not be put in a command is 400 malformed, never copied into the text" do
    [ "evil.example/$(touch x)", "a b", "host;rm", "host`x`" ].each do |host|
      prompt(@builder, host: host)
      assert_response :bad_request, host
      assert_equal "malformed", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
      refute_includes response.body, "touch x"
    end
  end

  test "a seat the app runs is refused 409 invalid_state with a Refusal" do
    app_run = scenario.seat(role: "builder", credential: scenario.credential, name: "Run by the app")

    prompt(app_run)

    assert_response :conflict
    assert_response_matches_contract
    assert_equal({ "code" => "invalid_state", "rule_id" => nil, "reason" => nil }, response.parsed_body)
  end

  test "an unknown seat, a removed seat, another workspace's seat and an id that is not a UUID are 404" do
    removed = scenario.seat(role: "builder")
    scenario.remove(removed)
    foreign = Scenario.new.seat(role: "builder")

    [ SecureRandom.uuid, removed.id, foreign.id, "not-an-id" ].each do |id|
      prompt(id)
      assert_response :not_found, id
      assert_equal "not_found", response.parsed_body.dig("error", "code")
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  test "it is 401 without an owner token, with a seat's token and with the helper's" do
    [ nil, scenario.token_for(@builder), scenario.helper_token ].each do |token|
      prompt(@builder, token: token)
      assert_response :unauthorized
      assert_matches_component("TransportError", response.parsed_body)
    end
  end

  test "reading it again gives the same text and writes nothing" do
    first = text_for(@builder)
    before = [ Command.count, Event.count, Workspace.find(scenario.workspace_id).last_seq ]
    assert_equal first, text_for(@builder)
    assert_equal before, [ Command.count, Event.count, Workspace.find(scenario.workspace_id).last_seq ]
  end

  test "the read is filled from one template file and has no second copy of the text" do
    template = Rails.root.join("config/landing_prompt.md.erb")
    assert template.file?, "api/config/landing_prompt.md.erb must exist"
    assert_includes template.read, "LEVERAGE_SEAT_TOKEN"
    source = Rails.root.join("lib/leverage/reads/landing_prompt.rb").read
    refute_includes source, "LEVERAGE_SEAT_TOKEN", "the wording lives in the template, not in the read"
  end

  test "the prompt reads as plain text a person can paste: no markup the agent would have to strip, one trailing newline" do
    text = text_for(@builder)
    refute_match(/<%|%>/, text, "no template tag may survive")
    assert text.end_with?("\n")
    refute text.end_with?("\n\n")
    refute_match(/\{\{|\}\}/, text)
  end
end
