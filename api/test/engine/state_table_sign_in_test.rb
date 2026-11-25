require "test_helper"

# The state table's rows for the sign-in group (test 3, PRD L836; milestone
# 2 plan WP6): create_owner, sign_in, sign_out and both token commands. Each
# row reads no task state (from: null) and changes none (to: null), so each
# case runs the real entry through the pipeline for a caller the row's
# "who" names and checks its outcome and events. create_owner writes
# rule.created once for each shipped rule (milestone 4 plan RD-1, RD-2;
# SM-33) and project.created for the Imaginarium. issue_seat_token also
# puts the seat's run on the start request's credential (milestone 3 plan
# HD-3).
class StateTableSignInTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  # The request kind of a row's "who" for each command: the owner, or the
  # helper acting as the app (the registry's caller of issue_seat_token).
  CALLERS = { "create_owner" => "owner", "sign_in" => "owner", "sign_out" => "owner", "issue_seat_token" => "helper",
    "issue_landing_prompt" => "owner" }.freeze

  def key = "state-table-#{SecureRandom.hex(4)}"

  # The request each command runs with, built from what the case needs.
  def request_for(kase)
    command = kase.command
    case command
    when "create_owner"
      Session.delete_all
      User.delete_all
      T::Request.new(command: command, workspace_id: nil, caller_kind: "owner", caller_id: nil, key: key,
        request_hash: "a" * 64, params: { "email_address" => "owner@example.test", "password" => "made-up-password-1" })
    when "sign_in"
      scenario = Scenario.new
      T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "owner",
        caller_id: scenario.owner.id, key: key, request_hash: "b" * 64, params: { "email_address" => scenario.owner.email_address })
    when "sign_out"
      scenario = Scenario.new
      session = scenario.owner_session
      T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "owner", caller_id: session.user_id,
        key: key, request_hash: "c" * 64, params: { "session_id" => session.id })
    when "issue_landing_prompt"
      scenario = Scenario.new
      @landing_seat = case kase.guard
      when %w[seat_has_not_landed]
        scenario.seat(token: false)
      when %w[seat_has_landed]
        seat = scenario.seat
        assert T::RecordPoll.seat(seat)
        seat.reload
      else
        flunk "no landing prompt setup for #{kase.guard.inspect}"
      end
      T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "owner",
        caller_id: scenario.owner.id, key: key, request_hash: "e" * 64,
        params: { "id" => @landing_seat.id, "connection" => "http", "address" => "http://example.test" })
    when "issue_seat_token"
      scenario = Scenario.new
      seat = scenario.seat(credential: scenario.credential, token: false)
      request = HelperRequest.create!(workspace_id: scenario.workspace_id, kind: "start_seat", seat_id: seat.id,
        credential_id: seat.credential_id, state: "picked_up", requested_at: scenario.database_now,
        params: { "role" => "builder", "provider" => "claude" })
      @start = request
      T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: "helper",
        caller_id: scenario.helper.id, key: key, request_hash: "d" * 64, params: { "id" => request.id })
    else
      flunk "no request for #{command}"
    end
  end

  test "the sign-in group covers the owner session and seat token commands" do
    assert_equal %w[create_owner sign_in sign_out issue_seat_token issue_landing_prompt], T::Table::SIGN_IN
  end

  StateTableCases.define(self, Leverage::Transitions::Table::SIGN_IN) do |kase|
    assert_nil kase.from, "the sign-in rows read no task state"
    assert_nil kase.to, "the sign-in rows change no task state"
    assert_nil kase.refusal unless kase.command == "issue_landing_prompt"
    assert_nil kase.hook, "no sign-in row has a hook in milestone 2"

    who = CALLERS.fetch(kase.command)
    assert_includes kase.who, who, "#{kase.command} is called by #{who}"

    request = request_for(kase)
    events_before = Event.pluck(:id)
    outcome = T.apply(request)

    if kase.refusal
      assert outcome.refused?, "#{kase.command} refused (got #{outcome.outcome})"
      assert_equal kase.refusal, outcome.refusal&.code
    else
      assert outcome.completed?, "#{kase.command} completed (got #{outcome.outcome} #{outcome.refusal&.code})"
    end
    written = Event.where.not(id: events_before).order(:seq).map(&:type)
    # create_owner's row names rule.created once for each shipped rule, then
    # the Imaginarium project's project.created once (DB-53).
    expected = if kase.command == "create_owner"
      [ "rule.created" ] * Leverage::Rules::Shipped.all.size + [ "project.created" ]
    else
      kase.events
    end
    assert_equal expected, written, "#{kase.command} writes exactly the row's events: #{kase.events.inspect}"
    assert_empty kase.conditional_events
    receipt = Command.find_by!(key: request.key, command: kase.command)
    assert_equal outcome.outcome.to_s, receipt.outcome
    if kase.command == "issue_landing_prompt"
      assert_landing_prompt(outcome, receipt)
    elsif kase.command == "issue_seat_token"
      assert_equal @start.credential_id, Seat.find(@start.seat_id).run_credential_id,
        "the seat's run is on the credential of the start it was issued for (milestone 3 plan HD-3)"
    end
  end

  private

  def assert_landing_prompt(outcome, receipt)
    if outcome.refused?
      token_hash_before = @landing_seat.token_hash
      assert_nil outcome.once
      assert_nil receipt.result
      assert_equal "invalid_state", receipt.refusal.fetch("code")
      assert_equal token_hash_before, @landing_seat.reload.token_hash
    else
      token = outcome.once.fetch("seat_token")
      assert_match Leverage::Tokens::FORM, token
      assert_includes outcome.once.fetch("text"), token
      assert_equal Leverage::Tokens.digest(token), @landing_seat.reload.token_hash
      assert_equal({ "seat_id" => @landing_seat.id, "connection" => "http" }, receipt.result)
    end
  end
end
