require_relative "http_trace_runner"

# What the integration tests of milestone 4 share (its plan WP13, RT-2).
#
#   include IntegrationHelpers   (in an ActionDispatch::IntegrationTest
#                                 that includes HttpCalls)
#   turn_shipped_rules_off(owner_token)
module IntegrationHelpers
  # Sends disable_rule through the owner interface for every shipped rule
  # that is on, as list_rules answers them, and leaves a rule that is off
  # as it is, so a second call changes nothing (RT-2: a test that creates
  # its owner through the real command gets the shipped rules, and a test
  # that proves the rule-free loop turns them off first). Answers the ids
  # it turned off.
  def turn_shipped_rules_off(owner_token)
    call("list_rules", token: owner_token)
    assert_response :ok
    assert_response_matches_contract
    on = response.parsed_body.fetch("rules").select do |row|
      row.dig("version", "origin") == "shipped" && row.dig("rule", "enabled")
    end
    on.map do |row|
      call("disable_rule", token: owner_token, key: new_key("rules-off"), ids: { "id" => row.dig("rule", "id") })
      assert_response :ok, response.body
      assert_response_matches_contract
      assert_equal "completed", response.parsed_body.fetch("outcome"), row.dig("rule", "key")
      row.dig("rule", "id")
    end
  end
end

# HttpTraceRunner for the traces of milestone 4 (16 to 19; its plan RT-1,
# WP13): what they need beyond the rule-free traces 09 to 15.
#
# - A command that waits answers 202 with its pending outcome (IN-4,
#   RE-3), which the runner compares as it compares 200 and 409.
# - The setup's rules and projects are rows Scenario inserts with
#   TraceBinder's ids, as the engine run seeds them (TraceRunner): no
#   command makes a project before milestone 5 (RD-52), and the setup's
#   rules stand for those create_owner writes, with the setup's switches
#   (the owner itself comes from Scenario here too, for the reason
#   HttpTraceRunner gives). Everything else is built over HTTP as before.
# - Add credential gives each login the next position; a setup whose
#   positions skip one (trace 19's, which lost a second Gemini login,
#   WP12) has its own positions put back after each add. A position only
#   orders a seat's candidates.
# - A setup login limited until a later time is added over HTTP, its
#   seats connected and their runs started on their own logins, and only
#   then limited, as the engine run's Scenario has it (a run that started
#   on another login would be another setup).
# - Presence: each orchestrator's and planner's last poll is placed before
#   every command as the engine run places it (TraceRunner#place_polls),
#   from the setup's last_polled_at on.
class RuleTraceHttpRunner < HttpTraceRunner
  # The last seq of what Scenario inserted (the owner, the rules and the
  # projects): the log audit reads everything after it, the setup built
  # over HTTP included.
  attr_reader :audit_from

  # The id bound to a trace's symbol, for checks between commands.
  def bound_id(symbol) = bound(symbol)

  # The key a trace's $key: symbol stands for.
  def key_for(symbol) = key_id(symbol)

  private

  def seed
    setup = trace.fetch("setup")
    bound = @binder.bind(setup.slice("rules", "projects"))
    %w[rules projects].each do |table|
      Array(setup[table]).each { |row| bind_symbol(row.fetch("id"), @binder.id(row.fetch("id")), "setup") }
    end
    Array(setup["rules"]).each do |row|
      bind_symbol(row.fetch("current_version_id"), @binder.id(row.fetch("current_version_id")), "setup")
    end
    @scenario = Scenario.new(**setup.fetch("settings").transform_keys(&:to_sym))
    bind_symbol(setup.dig("users", 0, "id"), scenario.owner.id, "setup")
    @tokens[setup.dig("users", 0, "id")] = scenario.owner_token
    scenario.seed("rules" => Array(bound["rules"]), "projects" => Array(bound["projects"]))
    @audit_from = scenario.workspace.reload.last_seq
    seed_helper(setup.dig("helpers", 0))
    credentials = setup.fetch("credentials").sort_by { |row| row.fetch("position") }
    credentials.each do |row|
      following = Credential.where(workspace_id: workspace_id).maximum(:position).to_i + 1
      seed_credential(row.merge("position" => following, "limited_until" => nil, "limited_since" => nil))
      Credential.where(id: bound(row.fetch("id"))).update_all(position: row.fetch("position"))
    end
    setup.fetch("seats").each { |row| seed_seat(row) }
    limit_after_setup(credentials)
    setup.fetch("seats").each do |row|
      @polls[row.fetch("id")] = [ seconds(row["last_polled_at"]) ] if row["last_polled_at"]
    end
    @setup_seq = scenario.workspace.reload.last_seq
  end

  # TraceRunner#limited_in_setup, for logins whose ids came from Add
  # credential over HTTP.
  def limit_after_setup(credentials)
    credentials.each do |row|
      next unless row["limited_until"]

      @command_seconds = 0
      values = { limited_until: sent_time(seconds(row.fetch("limited_until"))) }
      values[:limited_since] = scenario.database_now + seconds(row["limited_since"]) if row["limited_since"]
      Credential.where(id: bound(row.fetch("id"))).update_all(values)
    end
  end

  # The sweep's seat_run_placement (milestone 3 plan HD-4) starts a seat
  # again whose run ended at a limit or a sign-out once the account its run
  # belongs on is available. The traces leave the sweep out (that timer
  # writes no event), and the engine run needs no token, so here, before a
  # seat with no run sends a command, the runner does what that timer
  # would for this seat alone, and hands the start over as the helper does
  # (trace 19: the orchestrator's login resets at 1400 and it claims at
  # 1420).
  def run_command(command, index, timer: nil)
    start_again(command.fetch("caller"))
    super
  end

  def start_again(caller)
    seat = Seat.find_by(id: @ids[caller]) if caller.start_with?("$seat:")
    return unless seat && seat.run_credential_id.nil? && Leverage::SeatRuns::INTERRUPTIONS.include?(seat.run_stop_reason)

    ActiveRecord::Base.transaction(requires_new: true) do
      ctx = scenario.context
      placement = Leverage::SeatRuns.placement(seat, at: ctx.at)
      next unless placement.credential && Leverage::Candidates.available?(placement.credential, ctx.at)

      Leverage::SeatRuns.ensure_run_on(ctx, seat, placement.credential, placement.work)
      @test.assert_empty ctx.events, "starting a run again writes no event"
    end
    helper_turn
  end

  def outcome_of(response, where)
    return super unless response.status == 202

    body = response.parsed_body
    return super unless body["outcome"] == "pending"

    Leverage::Transitions::Outcome.new(outcome: "pending", result: body["result"])
  end
end
