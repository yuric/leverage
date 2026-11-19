# What the tests of the ACCOUNTS entries share (milestone 2 plan WP7): a
# request from the owner or the helper, run through the real pipeline, and
# the events a command wrote. Every value is made up.
#
#   class AddCredentialTest < ActiveSupport::TestCase
#     include AccountsSupport
#     setup { use_scenario }
#     test "..." { outcome = owner_command("add_credential", { ... }) }
#   end
module AccountsSupport
  T = Leverage::Transitions

  attr_reader :scenario

  # A new Scenario, with its owner and its helper.
  def use_scenario(**settings)
    @scenario = Scenario.new(**settings)
    @scenario.owner
    @scenario.helper
    @scenario
  end

  def new_key = "key-#{SecureRandom.hex(6)}"

  # A Request as the owner's controller builds it: params is the checked
  # body plus the path's ids ("id", or "provider" for install_tool).
  def owner_request(command, params = {}, key: new_key, scenario: self.scenario)
    request(command, params, key: key, caller_kind: "owner", caller_id: scenario.owner.id, scenario: scenario)
  end

  # A Request as the helper's controller builds it.
  def helper_request(command, params = {}, key: new_key, scenario: self.scenario)
    request(command, params, key: key, caller_kind: "helper", caller_id: scenario.helper.id, scenario: scenario)
  end

  def request(command, params, key:, caller_kind:, caller_id:, scenario:)
    T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: caller_kind, caller_id: caller_id,
      key: key, request_hash: Leverage::Idempotency.request_hash(method: "POST", path: "/test/#{command}",
        body: JSON.generate(params)), params: params)
  end

  def owner_command(command, params = {}, **options) = T.apply(owner_request(command, params, **options))
  def helper_command(command, params = {}, **options) = T.apply(helper_request(command, params, **options))

  # Runs the block and returns the events it wrote in this workspace, in
  # seq order.
  def events_written(scenario: self.scenario)
    before = scenario.workspace.reload.last_seq
    yield
    Event.where(workspace_id: scenario.workspace_id).where("seq > ?", before).order(:seq).to_a
  end

  def assert_completed(outcome)
    assert outcome.completed?, "expected completed, got #{outcome.outcome} #{outcome.refusal&.code}"
    outcome
  end

  def assert_refused(code, outcome)
    assert outcome.refused?, "expected refused #{code}, got #{outcome.outcome}"
    assert_equal code, outcome.refusal.code
    outcome
  end

  # A helper request in this workspace.
  def queue_request(kind, seat: nil, credential: nil, state: "queued", params: {}, scenario: self.scenario)
    HelperRequest.create!(workspace_id: scenario.workspace_id, kind: kind, seat_id: seat&.id,
      credential_id: credential&.id, state: state, requested_at: scenario.database_now, params: params,
      picked_up_at: (scenario.database_now unless state == "queued"))
  end

  # A seat the app runs, on an added login, marked running by the helper.
  def running_seat(role: "builder", **columns)
    scenario.seat(role: role, credential: scenario.credential, run_state: "running", wanted_running: true, **columns)
  end

  # A seat that connects on its own.
  def own_seat(role: "builder", **columns)
    scenario.seat(role: role, provider: "codex", **columns)
  end

  # Whether a seat's token still signs it in.
  def signs_in?(seat)
    token = scenario.token_for(seat)
    !Leverage::Tokens.find(token, kind: :seat).nil?
  end

  # A check result of HelperRequestResult.
  def check(name, passed: true, failure: nil)
    { "check" => name, "passed" => passed, "failure" => failure }
  end

  def login_checks(failed: nil, failure: "not_signed_in")
    %w[tool_installed signed_in test_prompt].map do |name|
      name == failed ? check(name, passed: false, failure: failure) : check(name)
    end
  end

  def result_body(outcome: "finished", checks: login_checks, plan: nil, account_email: nil, tool_version: "9.9.9-made-up")
    { "outcome" => outcome, "checks" => checks, "tool_version" => tool_version, "plan" => plan,
      "account_email" => account_email }
  end
end
