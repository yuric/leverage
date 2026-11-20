require_relative "contract_helper"

# The Handoff milestone's additions to the contract (milestone 3 plan,
# section 2.3): the workspace timer seat_run_placement and its command, the
# meanings of four guards and of the credential hold's due time, the side
# events four rows gain, what closes a limit with no reset time, the
# descriptions of the reports, Sign in again and hold.opened, and the
# fields the provisional reads gain. Every name is read from the contract
# files.
class HandoffContractTest < Minitest::Test
  include ContractTestHelpers

  def doc = Leverage::Contract.openapi
  def schemas = doc.fetch("components").fetch("schemas")
  def sm = Leverage::Contract.state_machine
  def rows = sm.fetch("groups").flat_map { |group| group.fetch("rows") }
  def timer(name) = Leverage::Contract.timers.fetch("timers").find { |entry| entry["timer"] == name }

  def operation(operation_id)
    doc.fetch("paths").each_value do |item|
      item.each_value { |op| return op if op.is_a?(Hash) && op["operationId"] == operation_id }
    end
    flunk "no operation #{operation_id} in openapi.json"
  end

  def guard(name)
    (sm.fetch("guard_families").flat_map { |family| family["guards"] } + sm.fetch("guard_conditions"))
      .find { |entry| entry["guard"] == name } or flunk("no guard #{name}")
  end

  def side_events(row, event) = row.fetch("side_events").select { |entry| entry["event"] == event }
  def notes(row, event) = side_events(row, event).map { |entry| entry["note"].to_s }

  def validator(component) = JSONSchemer.openapi(doc).ref("#/components/schemas/#{component}")

  # Plan HD-4: a workspace timer every sweep fires, which moves a seat's run
  # to its first available candidate and starts again a run its account
  # ended. It writes no event.
  def test_seat_run_placement_is_a_workspace_timer_of_every_sweep_that_writes_no_event
    entry = timer("seat_run_placement")
    refute_nil entry, "timers.json has no seat_run_placement"
    assert_equal "workspace", entry["scope"]
    assert_equal "sweep_runs.ran_at", entry.dig("due_at", "source")
    assert_includes entry.dig("due_at", "plus"), "every sweep"
    assert_empty entry["events"]
    refute_nil entry["note"]
    assert_includes registry.fetch("commands"), "seat_run_placement"
    command = sm.fetch("commands").find { |candidate| candidate["command"] == "seat_run_placement" }
    refute_nil command, "state_machine.json commands has no seat_run_placement"
    assert_equal [ false, false, false ], command.values_at("work_call", "blocked_by_hold", "allowed_while_pending")
    timers = sm.fetch("groups").find { |group| group["id"] == "timers" }
    same = timers.fetch("rows").select { |row| row["command"] == "seat_run_placement" }
    assert_equal 1, same.size, "one row in the derived timers group"
    row = same.first
    assert_nil row["from"]
    assert_equal [ "app" ], row["who"]
    assert_equal [], row["events"]
    assert_equal [], row["conditional_events"]
    assert_equal [], row["side_events"]
    assert_includes row["note"], "HD-4"
    assert_equal 1, rows.count { |candidate| candidate["command"] == "seat_run_placement" }
  end

  # Plan section 2.1, rule 4, and HE-4: a report takes the first available
  # candidate below the stopped one or, when none is, the seat's own.
  def test_candidate_available_includes_the_seats_own_credential_when_none_below_is
    assert_includes guard("candidate_available")["means"], "the seat's own credential"
    assert_includes guard("no_candidate_available")["means"], "the seat's own credential"
    assert_includes guard("candidate_available")["means"], "HE-4"
  end

  # Rule 6 and HE-4: no item when a candidate the report does not take is
  # available, because the hold is then due at once.
  def test_owner_must_act_is_rule_6s_condition
    means = guard("owner_must_act")["means"]
    assert_includes means, "A candidate is signed out, or no candidate has a reset time"
    assert_includes means, "between the seat's own credential and the stopped one"
  end

  # HE-14: a fresh lease goes to a builder the app runs only when one of
  # its candidates is available.
  def test_builder_free_needs_an_available_candidate_for_a_seat_the_app_runs
    assert_includes guard("builder_free")["means"], "one of its candidates is available"
    assert_includes guard("builder_busy")["means"], "none of its candidates is available"
  end

  # HE-23 and rule 8: the due time of a credential hold.
  def test_the_credential_hold_releases_due_time_is_rule_8
    plus = timer("credential_hold_release").dig("due_at", "plus")
    assert_includes plus, "at once"
    assert_includes plus, "last effective time"
    assert_includes plus, "HE-23"
    rows.select { |row| row["command"] == "credential_hold_release" && row["from"] == "working" }.each do |row|
      assert_includes row["note"], "HE-23"
    end
  end

  # HE-2, HE-10, HE-11: a Verify's or a sign-in's result may close a
  # credential_limit hold too, resolve "Limit with no reset time", open
  # "Account signed out" beside a limit hold a sign-out leaves with no due
  # time, and resolve "Account signed out" while the hold stays open.
  def test_report_request_result_may_close_a_limit_hold_and_open_or_resolve_the_credential_items
    row = rows.find { |candidate| candidate["command"] == "report_request_result" }
    assert_includes row["holds_closed"], "credential_limit"
    assert_includes row["holds_closed"], "credential_signed_out"
    assert notes(row, "hold.closed").any? { |note| note.include?("credential_limit") && note.include?("HE-2") }
    assert notes(row, "inbox.resolved").any? { |note| note.start_with?("Limit with no reset time") }
    assert notes(row, "inbox.resolved").any? { |note| note.start_with?("Account signed out") && note.include?("HE-11") }
    assert notes(row, "inbox.opened").any? { |note| note.start_with?("Account signed out") && note.include?("HE-11") }
  end

  # HE-11: the reports that write credential.signed_out may open "Account
  # signed out" beside another task's credential_limit hold.
  def test_the_sign_out_reports_may_open_account_signed_out_beside_another_tasks_limit_hold
    reports = rows.select { |row| row["command"] == "report_signed_out" && !row["refusal"] }
    refute_empty reports
    reports.each do |row|
      assert notes(row, "inbox.opened").any? { |note| note.start_with?("Account signed out") && note.include?("HE-11") },
        "#{row["command"]} from #{row["from"]} #{row["guard"]}"
    end
    rows.select { |row| row["command"] == "report_limit" }.each do |row|
      refute notes(row, "inbox.opened").any? { |note| note.include?("HE-11") }, "a limit report signs nobody out"
    end
  end

  # HE-10 and HE-27: a change that gives the seat another credential may
  # close its credential hold, switch the credential and resolve the item.
  def test_change_seat_may_close_a_credential_hold_when_it_changes_the_seats_credential
    row = rows.find { |candidate| candidate["command"] == "change_seat" }
    assert side_events(row, "credential.switched").any? { |entry| entry["when"] == "credential_differs" }
    closing = side_events(row, "hold.closed").reject { |entry| entry["when"] == "seat_disabled_by_change" }
    assert_equal 1, closing.size, "one hold.closed for the change of credential"
    assert_includes closing.first["note"], "HE-27"
    assert side_events(row, "inbox.resolved").any? { |entry| entry["note"].to_s.include?("HE-27") }
  end

  # HE-2: until the usage readers exist, a passed Verify is the reading.
  def test_a_limit_with_no_reset_time_closes_when_a_verify_passes
    item = Leverage::Contract.needs_you.fetch("items").find { |entry| entry["item"] == "limit_with_no_reset_time" }
    assert_includes item["closes"], "Verify"
    assert_includes item["closes"], "HE-2"
    assert_equal "None. It closes when a reading shows capacity.", item["prd_choices"]
  end

  # HE-12, HE-13: which credential a credential hold names.
  def test_hold_opened_says_which_credential_a_credential_hold_names
    description = Leverage::Contract.payload_schema("hold.opened", 1).dig("properties", "credential_id", "description")
    assert_includes description, "first signed-out candidate"
    assert_includes description, "HE-12"
    assert_includes description, "the credential that stopped"
    assert_includes description, "HE-13"
  end

  # HE-8, HE-33, HE-36: what the reports and Sign in again answer.
  def test_the_reports_answer_no_result_and_sign_in_again_answers_its_request
    %w[report_limit report_signed_out].each do |id|
      description = operation(id).fetch("description")
      assert_includes description, "`result` is null", id
      assert_includes description, "get_helper_next", id
      assert_includes description, "HE-33", id
    end
    description = operation("sign_in_again").fetch("description")
    assert_includes description, "helper_request_id"
    assert_includes description, "open_sign_in"
    assert_includes operation("get_helper_request").fetch("description"), "Sign in again"
  end

  # HD-1: a start request names the work its run continues.
  def test_a_helper_requests_params_may_name_the_task_or_review_to_continue
    params = schemas.fetch("HelperRequestParams")
    %w[task_id review_id].each do |field|
      assert_equal %w[string null], params.dig("properties", field, "type"), field
      assert_equal "uuid", params.dig("properties", field, "format"), field
    end
    assert_equal false, params["additionalProperties"]
    assert_empty params.fetch("properties").keys.grep(/\Aname\z|(\A|_)token\z/i)
    start = { "role" => "builder", "provider" => "claude", "model" => "made-up-model", "effort" => nil,
              "task_id" => "00000000-0000-4000-8000-000000000901", "review_id" => nil }
    assert validator("HelperRequestParams").valid?(start)
    assert params.fetch("examples").any? { |example| example.key?("task_id") }
  end

  # HE-3: a credential says since when it is limited.
  def test_a_credential_carries_limited_since
    credential = schemas.fetch("Credential")
    assert_includes credential.fetch("required"), "limited_since"
    assert_equal %w[string null], credential.dig("properties", "limited_since", "type")
    assert_equal "date-time", credential.dig("properties", "limited_since", "format")
  end

  # HD-3, HD-10: the credential a seat's run is on, and why its last run
  # ended.
  def test_a_seat_carries_its_runs_credential_and_why_its_last_run_ended
    seat = schemas.fetch("Seat")
    %w[run_credential_id run_stop_reason].each { |field| assert_includes seat.fetch("required"), field }
    assert_equal %w[string null], seat.dig("properties", "run_credential_id", "type")
    assert_equal "uuid", seat.dig("properties", "run_credential_id", "format")
    reasons = schemas.dig("RunStoppedReport", "properties", "stop_reason", "enum")
    assert_equal reasons + [ nil ], seat.dig("properties", "run_stop_reason", "enum")
  end

  # HE-17, HE-18: the task read carries its recovery times.
  def test_the_task_page_carries_its_recovery_times
    page = schemas.fetch("TaskPage")
    assert_includes page.fetch("required"), "recovery_times"
    assert_equal "#/components/schemas/RecoveryTime", page.dig("properties", "recovery_times", "items", "$ref")
    recovery = schemas.fetch("RecoveryTime")
    assert_equal %w[credential_id ended_at ended_by kind review_id seconds started_at], recovery.fetch("required").sort
    assert_equal false, recovery["additionalProperties"]
    assert_equal %w[limit signed_out], recovery.dig("properties", "kind", "enum")
    assert_includes recovery.fetch("description"), "HE-17"
    assert_includes page.dig("properties", "names", "description"), "recovery times"
  end

  # HB-4: the health line says when the last backup ran and whether the
  # daily backup is late.
  def test_system_health_carries_the_last_backup_and_whether_it_is_late
    health = schemas.fetch("SystemHealth")
    %w[backup_last_ran_at backup_late].each { |field| assert_includes health.fetch("required"), field }
    assert_equal "date-time", health.dig("properties", "backup_last_ran_at", "format")
    assert_equal "boolean", health.dig("properties", "backup_late", "type")
    assert_includes health.dig("properties", "backup_late", "description"), "26 hours"
  end

  # Plan section 2.3: the ceiling still has no value (HE-1), and every
  # login reader stays provisional with nothing captured (HD-8).
  def test_the_ceiling_and_the_readers_are_not_touched
    assert_equal "Workspace settings. The recovery time ceiling has no value yet.", schemas.fetch("WorkspaceSettings")["description"]
    Leverage::Contract.readers.fetch("readers").each do |reader|
      next unless reader["capture"]

      assert_equal "none", reader.dig("capture", "limit"), reader["provider"]
      assert_equal "none", reader.dig("capture", "sign_out"), reader["provider"]
    end
  end

  def test_the_readme_records_the_handoff_milestones_additions
    readme = File.read(File.join(CONTRACT_ROOT, "README.md"))
    section = readme.split(/^## /).find { |part| part.start_with?("What the Handoff milestone added") }
    refute_nil section, "README.md has no section for the Handoff milestone"
    %w[seat_run_placement candidate_available owner_must_act builder_free limited_since run_credential_id
       RecoveryTime backup_late task_id backup_runs].each do |name|
      assert_includes section, name
    end
  end
end
