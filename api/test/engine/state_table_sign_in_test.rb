require "test_helper"

# The state table's rows for the sign-in group (test 3, PRD L836; milestone
# 2 plan WP6): create_owner, sign_in, sign_out and issue_seat_token. Each
# row reads no task state (from: null) and changes none (to: null), so each
# case runs the real entry through the pipeline for a caller the row's
# "who" names and checks that the command completed and wrote exactly the
# row's events: none, but create_owner's rule.created, once for each
# shipped rule (milestone 4 plan RD-1, RD-2; SM-33). issue_seat_token also
# puts the seat's run on the start request's credential (milestone 3 plan
# HD-3).
class StateTableSignInTest < ActiveSupport::TestCase
  T = Leverage::Transitions

  # The request kind of a row's "who" for each command: the owner, or the
  # helper acting as the app (the registry's caller of issue_seat_token).
  CALLERS = { "create_owner" => "owner", "sign_in" => "owner", "sign_out" => "owner", "issue_seat_token" => "helper" }.freeze

  def key = "state-table-#{SecureRandom.hex(4)}"

  # The request each command runs with, built from what the case needs.
  def request_for(command)
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

  test "the sign-in group is the four commands of plan section 2.1" do
    assert_equal %w[create_owner sign_in sign_out issue_seat_token], T::Table::SIGN_IN
  end

  StateTableCases.define(self, Leverage::Transitions::Table::SIGN_IN) do |kase|
    assert_nil kase.from, "the sign-in rows read no task state"
    assert_nil kase.to, "the sign-in rows change no task state"
    assert_nil kase.refusal
    assert_nil kase.hook, "no sign-in row has a hook in milestone 2"

    who = CALLERS.fetch(kase.command)
    assert_includes kase.who, who, "#{kase.command} is called by #{who}"

    request = request_for(kase.command)
    events_before = Event.pluck(:id)
    outcome = T.apply(request)

    assert outcome.completed?, "#{kase.command} completed (got #{outcome.outcome} #{outcome.refusal&.code})"
    written = Event.where.not(id: events_before).order(:seq).map(&:type)
    times = kase.command == "create_owner" ? Leverage::Rules::Shipped.all.size : 1
    assert_equal kase.events * times, written, "#{kase.command} writes exactly the row's events: #{kase.events.inspect}"
    assert_empty kase.conditional_events
    assert Command.exists?(key: request.key, command: kase.command), "#{kase.command} stores its commands row"
    if kase.command == "issue_seat_token"
      assert_equal @start.credential_id, Seat.find(@start.seat_id).run_credential_id,
        "the seat's run is on the credential of the start it was issued for (milestone 3 plan HD-3)"
    end
  end
end
