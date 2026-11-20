require "test_helper"
require_relative "entries/accounts_support"

# The state table's rows for the accounts group (test 3, PRD L836; milestone
# 2 plan WP7): credentials, seats and the helper's requests and reports.
# Every row reads no task state (from: null) and changes none, so each case
# runs the real entry through the pipeline as the caller the row's "who"
# names, from a state where none of the row's conditions holds, and checks
# that it completed, stored its commands row and wrote exactly the row's
# events. Each conditional event is proven in the entry's own test
# (test/engine/entries/); side events that need rules or later milestones
# are not written (SC-11).
#
# Milestone 3 (plan HT-2) adds the rows of sign_in_again (Table::HANDOFF)
# and of the seat_run_placement timer (Table::TIMERS): neither reads or
# changes a task state, and neither writes an event.
class StateTableAccountsTest < ActiveSupport::TestCase
  include AccountsSupport

  # The conditional events of each row and the entry test that proves each.
  CONDITIONAL = {
    "issue_helper_token" => { "review.released" => "seat_holds_review" },
    "remove_seat" => { "task.released" => "seat_holds_working_task", "review.released" => "seat_holds_review" },
    "report_run_stopped" => { "review.released" => "seat_holds_review" },
    "report_request_result" => { "credential.added" => "add_checks_passed", "credential.verified" => "verify_passed",
                                 "credential.signed_out" => "found_signed_out" }
  }.freeze

  setup { use_scenario }

  def caller_of(command) = Leverage::Contract.state_machine.fetch("groups").flat_map { |group| group.fetch("rows") }
    .find { |row| row.fetch("command") == command }.fetch("who").first

  # The request each command runs with.
  def request_for(command)
    case command
    when "issue_helper_token" then owner_request(command, { "name" => "Made-up Mac" })
    when "add_credential"
      owner_request(command, { "credential_id" => SecureRandom.uuid, "kind" => "login", "provider" => "codex",
                               "name" => "Made-up table account", "masked_label" => nil, "model" => nil, "effort" => nil,
                               "strength_rank" => nil })
    when "verify_credential" then owner_request(command, { "id" => scenario.credential.id })
    when "install_tool" then owner_request(command, { "provider" => "claude", "confirmed" => true })
    when "connect_seat" then owner_request(command, { "name" => "Made-up table seat", "role" => "builder", "provider" => "codex" })
    when "start_seat" then owner_request(command, { "id" => scenario.seat(credential: scenario.credential).id })
    when "stop_seat" then owner_request(command, { "id" => running_seat.id })
    when "remove_seat" then owner_request(command, { "id" => own_seat.id })
    when "report_request_progress"
      request = queue_request("verify", credential: scenario.credential, state: "picked_up")
      helper_request(command, { "id" => request.id, "check" => "signed_in", "state" => "running", "failure" => nil,
                                "install" => nil })
    when "report_request_result"
      request = queue_request("install_tool", state: "picked_up", params: { "provider" => "claude" })
      helper_request(command, { "id" => request.id, "result" => result_body(checks: []) })
    when "report_run_started"
      seat = scenario.seat(credential: scenario.credential, run_state: "stopped")
      helper_request(command, { "id" => seat.id, "credential_id" => seat.credential_id,
                                "observed_at" => "2026-11-19T12:00:00Z", "tool_version" => "9.9.9-made-up" })
    when "report_run_stopped"
      seat = running_seat
      helper_request(command, { "id" => seat.id, "credential_id" => seat.credential_id,
                                "observed_at" => "2026-11-19T12:00:00Z", "stop_reason" => "stopped" })
    else
      flunk "no request for #{command}"
    end
  end

  # The two milestone 3 commands of plan HT-2 and the case each runs.
  HANDOFF_ACCOUNTS = %w[sign_in_again seat_run_placement].freeze

  def milestone_3_request(command)
    case command
    when "sign_in_again" then owner_request(command, { "id" => scenario.credential(state: "signed_out").id })
    when "seat_run_placement"
      seat = scenario.seat(credential: scenario.credential, wanted_running: true)
      seat.update!(run_state: "stopped", run_credential_id: nil, run_stop_reason: "limit", token_hash: nil)
      T::Request.new(command: command, workspace_id: scenario.workspace_id, caller_kind: nil, caller_id: nil, key: nil,
        request_hash: nil, params: {})
    else
      flunk "no request for #{command}"
    end
  end

  test "sign_in_again is in Table::HANDOFF and seat_run_placement in Table::TIMERS" do
    assert_equal %w[sign_in_again], T::Table::HANDOFF & HANDOFF_ACCOUNTS
    assert_equal %w[seat_run_placement], T::Table::TIMERS & HANDOFF_ACCOUNTS
    HANDOFF_ACCOUNTS.each { |command| assert T::Table.include?(command), command }
  end

  StateTableCases.define(self, HANDOFF_ACCOUNTS) do |kase|
    assert_nil kase.from, "#{kase.command} reads no task state"
    assert_nil kase.to
    assert_nil kase.refusal
    assert_nil kase.hook
    assert_empty kase.conditional_events

    request = milestone_3_request(kase.command)
    if kase.who.first == "app"
      assert_nil request.caller_kind, "a timer is the app's own command"
    else
      assert_equal kase.who.first, request.caller_kind
    end
    queued = HelperRequest.where(workspace_id: scenario.workspace_id).count
    written = events_written { @outcome = T.apply(request) }

    assert_completed(@outcome)
    assert_equal kase.events, written.map(&:type), "#{kase.command} writes exactly the row's events: none"
    assert_equal queued + 1, HelperRequest.where(workspace_id: scenario.workspace_id).count,
      "#{kase.command} queues one helper request"
    assert Command.exists?(key: request.key, command: kase.command) if request.key
  end

  test "the accounts group is the twelve commands of plan section 2.1" do
    assert_equal %w[issue_helper_token add_credential verify_credential install_tool connect_seat start_seat stop_seat
                    remove_seat report_request_progress report_request_result report_run_started report_run_stopped],
      T::Table::ACCOUNTS
  end

  test "every conditional event of the group is named here and proven by its entry's test" do
    StateTableCases.for(T::Table::ACCOUNTS).each do |kase|
      named = kase.conditional_events.to_h { |conditional| [ conditional.fetch("event"), conditional.fetch("when") ] }
      assert_equal CONDITIONAL.fetch(kase.command, {}), named, kase.command
    end
  end

  StateTableCases.define(self, Leverage::Transitions::Table::ACCOUNTS) do |kase|
    assert_nil kase.from, "the accounts rows read no task state"
    assert_nil kase.to, "the accounts rows change no task state"
    assert_nil kase.refusal
    assert_nil kase.hook, "no accounts row has a hook in milestone 2"

    request = request_for(kase.command)
    assert_equal caller_of(kase.command), request.caller_kind
    written = events_written { @outcome = T.apply(request) }

    assert_completed(@outcome)
    assert_equal kase.events, written.map(&:type), "#{kase.command} writes exactly the row's events"
    assert Command.exists?(key: request.key, command: kase.command), "#{kase.command} stores its commands row"
  end
end
