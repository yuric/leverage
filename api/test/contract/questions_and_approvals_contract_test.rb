require_relative "contract_helper"

class QuestionsAndApprovalsContractTest < Minitest::Test
  include ContractTestHelpers

  def machine = Leverage::Contract.state_machine
  def openapi = Leverage::Contract.openapi
  def components = openapi.dig("components", "schemas")
  def rows(command) = machine.fetch("groups").flat_map { |group| group.fetch("rows") }.select { |row| row["command"] == command }
  def accepted(command) = rows(command).reject { |row| row["refusal"] }
  def side_events(row) = row.fetch("side_events").map { |entry| entry.fetch("event") }
  def guard_family(name) = machine.fetch("guard_families").find { |entry| entry["family"] == name }
  def property(component, field) = components.dig(component, "properties", field)

  def test_overturn_after_done_has_an_empty_action_event_and_no_action_move
    type = "action.overturn_recorded"
    event = registry.fetch("event_types").find { |entry| entry["type"] == type }
    assert_equal [ "action" ], event&.fetch("subject_kinds")
    assert_equal [ 1 ], event.fetch("schema_versions")
    assert_empty Leverage::Contract.validate_payload(type, 1, {})
    refute_empty Leverage::Contract.validate_payload(type, 1, { "unexpected" => 1 })
    refute_includes machine.dig("action_machine", "transitions").map { |move| move["event"] }, type
  end

  def test_only_the_first_overturn_of_an_already_done_action_is_recorded
    done_rows = rows("overturn_approval").select { |row| row["guard"].include?("approved_action_done") }
    %w[finishing done].each do |state|
      by_guard = done_rows.select { |row| row["from"] == state }.to_h { |row| [ row["guard"].last, row ] }
      assert_equal %w[approval_already_overturned approval_not_yet_overturned], by_guard.keys.sort
      recording = by_guard.fetch("approval_not_yet_overturned")
      assert_equal [ "action.overturn_recorded" ], recording["events"]
      assert_equal state, recording["to"]
      assert_empty side_events(recording)
      assert_equal "invalid_state", by_guard.fetch("approval_already_overturned")["refusal"]
    end
  end

  def test_approve_requires_an_open_request_and_only_override_can_approve_a_stopped_action
    assert_equal %w[approval_asked_of_caller approval_not_asked_of_caller],
      guard_family("approval_asked")&.fetch("guards")&.map { |entry| entry["guard"] }
    assert_equal 3, accepted("approve_action").size
    accepted("approve_action").each { |row| assert_includes row["guard"], "approval_asked_of_caller" }
    refused = rows("approve_action").find { |row| row["guard"] == %w[approval_not_asked_of_caller] }
    assert_equal "invalid_state", refused&.fetch("refusal")
    moves = machine.dig("action_machine", "transitions").select { |move| move["event"] == "action.approved" }
    assert_equal({ %w[approve_action] => %w[requested], %w[override_check] => %w[stopped] },
      moves.to_h { |move| [ move["commands"], move["from"] ] })
  end

  def test_question_and_content_commands_record_their_refused_cases
    {
      "answer_question" => %w[question_answerable question_not_answerable],
      "overturn_answer" => %w[orchestrator_answer_not_overturned no_orchestrator_answer_to_overturn],
      "delete_content" => %w[content_deletable content_not_deletable]
    }.each do |command, (allowed, refused)|
      assert_equal [ [ allowed ] ], accepted(command).map { |row| row["guard"] }, command
      refusal = rows(command).find { |row| row["guard"] == [ refused ] }
      assert_equal "invalid_state", refusal&.fetch("refusal"), command
    end
    assert_match(/each.*task/i, accepted("delete_content").first["note"].to_s)
  end

  def test_offer_again_requires_an_enabled_builder
    offers = accepted("offer_task_again")
    assert_equal 3, offers.size
    offers.each { |row| assert_includes row["guard"], "builder_seat_enabled" }
    refused = rows("offer_task_again").find { |row| row["guard"].include?("builder_seat_unavailable") }
    assert_equal "invalid_state", refused&.fetch("refusal")
    assert_includes refused["guard"], "held_action_unconfirmed"
  end

  # A seat disabled in Finishing can be re-enabled while its former lease
  # is still paused by the unconfirmed action hold (AP-19, DB-43).
  def test_reenabled_builder_that_still_holds_the_task_gets_a_fresh_offer
    guards = %w[held_action_unconfirmed builder_seat_enabled builder_holds_task]
    row = accepted("offer_task_again").find { |candidate| candidate["guard"] == guards }
    assert_equal "fresh", row&.fetch("builder_lease")
    assert_equal [ "hold.closed" ], row["events"]
    assert_includes row["note"], "lease_seat_id"
  end

  def test_marking_one_action_done_keeps_the_reenabled_builders_held_lease
    guards = %w[held_action_unconfirmed not_last_open_action approvals_complete builder_holds_task]
    row = accepted("mark_action_done").find { |candidate| candidate["guard"] == guards }
    assert_equal "finishing", row&.fetch("to")
    assert_nil row["builder_lease"]
    assert_includes row["holds_closed"], "action_unconfirmed"
    assert_empty row["holds_opened"]
  end

  def test_rework_replaces_a_held_lease_and_waive_keeps_it
    assert_equal %w[builder_free builder_busy builder_holds_task],
      guard_family("builder_availability").fetch("guards").map { |entry| entry["guard"] }
    rework = rows("return_for_rework").find { |row| row["guard"].include?("builder_holds_task") }
    assert_equal "fresh", rework&.fetch("builder_lease")
    assert_equal "working", rework["to"]
    assert_includes rework["guard"], "no_action_started"
    waive = rows("waive_action").find { |row| row["guard"].include?("builder_holds_task") }
    assert_equal %w[not_last_open_action approvals_complete builder_holds_task], waive&.fetch("guard")
    assert_nil waive["builder_lease"]
    assert_includes waive["note"], "lease_seat_id"
  end

  def test_rework_closes_approval_holds_and_settling_can_open_an_unconfirmed_hold
    accepted("return_for_rework").each do |row|
      assert_empty %w[action_stopped owner_approval action_unconfirmed check_error] - row["holds_closed"]
      assert_empty %w[hold.closed inbox.resolved] - side_events(row)
    end
    %w[approve_action waive_action mark_action_done].each do |command|
      row = accepted(command).find { |candidate| candidate["guard"].include?("builder_busy") }
      assert_includes row["holds_opened"], "action_unconfirmed", command
      assert_empty %w[hold.opened inbox.opened] - side_events(row), command
      assert_match(/disabled or removed/, row["side_events"].find { |entry| entry["event"] == "hold.opened" }["note"])
    end
    %w[change_seat remove_seat].each do |command|
      assert_match(/approved action waits/, accepted(command).first["note"], command)
    end
  end

  def test_contract_changes_may_close_the_budget_hold
    %w[complete_contract edit_contract].each do |command|
      accepted(command).each do |row|
        assert_includes row["holds_closed"], "budget", command
        assert row["side_events"].any? { |entry| entry["event"] == "hold.closed" && entry["note"].to_s.include?("cap") }
        assert_includes side_events(row), "inbox.resolved", command
      end
    end
  end

  def test_rows_describe_questions_brief_edits_budget_holds_and_approval_timeouts
    accepted("ask_question").each { |row| assert_match(/no hold/, row["note"].to_s) }
    item = Leverage::Contract.needs_you.fetch("items").find { |entry| entry["item"] == "question_passed_on" }
    assert_match(/null/, item["closes"].to_s)
    assert_match(/each.*added or removed.*none/, accepted("edit_brief").first["note"].to_s)
    %w[pass_review fail_review report_cost].each do |command|
      accepted(command).each { |row| assert_match(/no budget hold/, row["note"].to_s, command) }
    end
    offline = rows("orchestrator_offline").first["side_events"].find { |entry| entry["event"] == "check.queued" }
    assert_match(/errored approval check.*final/, offline["note"])
  end

  def test_job_inputs_require_the_material_and_results_have_length_limits
    {
      "QuestionJobInput" => %w[role_file question contract brief earlier_answers],
      "ApprovalJobInput" => %w[role_file instruction action contract quoted]
    }.each do |component, required|
      assert_includes components.fetch(component).fetch("required"), "material"
      material_name = property(component, "material").fetch("$ref").split("/").last
      assert_equal required.sort, components.fetch(material_name).fetch("required").sort
    end
    schemer = JSONSchemer.openapi(openapi)
    { "QuestionJobResult" => [ "answer", 4_000 ], "ApprovalJobResult" => [ "reason", 500 ] }.each do |name, (field, limit)|
      schema = schemer.ref("#/components/schemas/#{name}")
      example = components.fetch(name).fetch("examples").first
      assert schema.valid?(example.merge(field => "x" * limit)), name
      refute schema.valid?(example.merge(field => "x" * (limit + 1))), name
    end
  end

  def test_workspace_settings_read_and_accepted_request_bounds
    read = openapi.dig("paths", "/v1/owner/settings", "get")
    assert_equal "get_workspace_settings", read&.fetch("operationId")
    assert_equal [ "read" ], read["x-leverage-command"]
    assert_equal "#/components/schemas/WorkspaceSettings", read.dig("responses", "200", "content", "application/json", "schema", "$ref")
    bounds = {
      "lease_length_seconds" => [ 300, 86_400 ], "check_queue_timeout_seconds" => [ 30, 3_600 ],
      "check_run_timeout_seconds" => [ 60, 3_600 ], "maximum_rounds" => [ 1, 20 ],
      "rerun_limit" => [ 1, 20 ], "recovery_time_ceiling_seconds" => [ 60, 86_400 ]
    }
    schema = JSONSchemer.openapi(openapi).ref("#/components/schemas/ChangeWorkspaceSettingsRequest")
    bounds.each do |field, (min, max)|
      assert schema.valid?({ field => min }), field
      assert schema.valid?({ field => max }), field
      refute schema.valid?({ field => min - 1 }), field
      refute schema.valid?({ field => max + 1 }), field
    end
    assert schema.valid?({ "recovery_time_ceiling_seconds" => nil })
  end

  def test_landing_prompt_and_seat_request_shapes
    path = "/v1/owner/seats/{id}/landing-prompt"
    connection = openapi.dig("paths", path, "get", "parameters").find { |entry| entry["name"] == "connection" }
    assert_equal "http", connection&.dig("schema", "default")
    assert_equal %w[http mcp], connection.dig("schema", "enum")
    assert_equal %w[http mcp], property("LandingPrompt", "connection")&.fetch("enum")
    %w[ConnectSeatRequest ChangeSeatRequest].each do |name|
      assert_equal [ 1, 3 ], property(name, "strength_rank").values_at("minimum", "maximum")
      refute_includes components.fetch(name).fetch("required"), "strength_rank"
    end
  end

  def test_provisional_reads_expose_the_questions_and_approvals_fields
    {
      "Decision" => %w[kind task_id task_title seat_id summary outcome action_state started overturned_at overturn_effect],
      "Project" => %w[brief paused_by open_tasks content_deleted_at],
      "TaskPage" => %w[any_action_started],
      "Action" => %w[approved_at position stopped_by_rule_check_id],
      "Question" => %w[asked_at answered_at overturned],
      "BoardTask" => %w[waits_for_builder waits_for_stronger_agent],
      "Briefing" => %w[answers]
    }.each do |name, fields|
      assert_empty fields - components.fetch(name).fetch("required"), name
    end
    assert_includes components.fetch("Action").fetch("required"), "state"
  end

  def test_important_event_types_are_the_registered_activity_selection
    types = registry.fetch("event_types").map { |entry| entry["type"] }
    action_events = types.grep(/\Aaction\./) - %w[action.requested action.lease_granted]
    expected = action_events + %w[
      task.created task.claimed task.submitted task.reassigned task.returned_for_rework task.done task.cancelled
      review.passed review.failed question.answered question.overturned inbox.opened check.overridden
      credential.limit_reached credential.signed_out credential.switched project.created project.paused project.resumed
      project.budget_changed rule.changed rule.enabled rule.disabled rule.reverted rule.removed seat.connected
      seat.removed workspace.settings_changed content.deleted
    ]
    selected = registry.dig("lists", "important_event_types")
    assert_kind_of Array, selected
    assert_equal expected.sort, selected.sort
    assert_empty selected - types
  end
end
