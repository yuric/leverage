require_relative "contract_helper"
require_relative "columns_test"

# The core loop's additions to the contract (milestone 2 plan, section 2.3
# and TS-8): six operations, the three commands they bring, the helper
# request's non-secret inputs and per-check progress, the shapes of the
# provisional owner reads, the landing prompt, and two traces written for a
# workspace with no rules. Every name is read from the contract files.
class CoreLoopContractTest < Minitest::Test
  include ContractTestHelpers

  ADDED_OPERATIONS = {
    "get_setup_state" => [ "GET", "/v1/owner/setup", "public", [ "read" ] ],
    "create_owner" => [ "POST", "/v1/owner/setup", "public", [ "create_owner" ] ],
    "sign_out_owner" => [ "POST", "/v1/owner/session/sign-out", "owner", [ "sign_out" ] ],
    "get_helper_request" => [ "GET", "/v1/owner/helper-requests/{id}", "owner", [ "read" ] ],
    "report_request_progress" => [ "POST", "/v1/helper/requests/{id}/progress", "helper", [ "report_request_progress" ] ],
    "get_landing_prompt" => [ "GET", "/v1/owner/seats/{id}/landing-prompt", "owner", [ "read" ] ]
  }.freeze

  ADDED_COMMANDS = %w[create_owner sign_out report_request_progress].freeze

  PROVISIONAL_SHAPES = {
    "get_board" => "Board", "get_task" => "TaskPage", "list_seats" => "SeatsList",
    "list_credentials" => "CredentialsList", "get_helper_request" => "HelperRequestStatus"
  }.freeze

  def doc = Leverage::Contract.openapi
  def schemas = doc.fetch("components").fetch("schemas")
  def sm = Leverage::Contract.state_machine

  def operation(operation_id)
    doc.fetch("paths").each_value do |item|
      item.each_value { |op| return op if op.is_a?(Hash) && op["operationId"] == operation_id }
    end
    flunk "no operation #{operation_id} in openapi.json"
  end

  def response_ref(operation_id, status)
    response = operation(operation_id).fetch("responses").fetch(status)
    response = doc.dig("components", "responses", response["$ref"].split("/").last) if response["$ref"]
    response.dig("content", "application/json", "schema", "$ref")
  end

  def parameter_names(operation_id)
    operation(operation_id).fetch("parameters", []).map do |parameter|
      parameter = doc.dig("components", "parameters", parameter["$ref"].split("/").last) if parameter["$ref"]
      parameter["name"]
    end
  end

  def validator(component) = JSONSchemer.openapi(doc).ref("#/components/schemas/#{component}")

  def test_the_six_operations_are_in_the_registry_and_in_openapi
    ADDED_OPERATIONS.each do |id, (method, path, caller, commands)|
      entry = registry.fetch("operations").find { |op| op["operation_id"] == id }
      refute_nil entry, "#{id} is not a registry operation"
      assert_equal [ method, path, caller, commands ], entry.values_at("method", "path", "caller", "commands"), id
      op = operation(id)
      assert_equal caller, op["x-leverage-caller"], id
      assert_equal commands, op["x-leverage-command"], id
    end
  end

  def test_the_three_commands_are_registered_with_derived_rows_that_write_no_event
    derived = sm.fetch("groups").reject { |group| group["source"] == "prd" }
    ADDED_COMMANDS.each do |command|
      assert_includes registry.fetch("commands"), command
      assert sm.fetch("commands").any? { |entry| entry["command"] == command }, "#{command} has no commands entry"
      rows = derived.flat_map { |group| group["rows"] }.select { |row| row["command"] == command }
      assert_equal 1, rows.size, "#{command}: one derived row"
      # Milestone 4 plan RD-2 and SM-33: from the Rule checks milestone on,
      # creating the workspace writes the shipped rules' rule.created
      # (RuleChecksContractTest holds that row).
      next if command == "create_owner"

      assert_equal [], rows.first["events"], command
      assert_equal [], rows.first["conditional_events"], command
    end
  end

  def test_setup_is_public_and_create_owner_answers_the_sign_in_envelope
    assert_equal [], operation("get_setup_state")["security"]
    assert_equal [], operation("create_owner")["security"]
    assert_equal "#/components/schemas/SetupState", response_ref("get_setup_state", "200")
    assert_equal %w[owner_exists], schemas.fetch("SetupState").fetch("required")
    assert_equal "#/components/schemas/OwnerSessionCompleted", response_ref("create_owner", "200")
    assert_equal "#/components/schemas/SignInRequest",
      operation("create_owner").dig("requestBody", "content", "application/json", "schema", "$ref")
    assert_includes parameter_names("create_owner"), "Idempotency-Key"
    assert operation("create_owner")["responses"].key?("404"), "a new key once an owner exists is 404 (IN-2)"
  end

  def test_sign_out_is_a_post_with_a_key_and_no_body
    op = operation("sign_out_owner")
    assert_includes parameter_names("sign_out_owner"), "Idempotency-Key"
    assert_nil op["requestBody"]
    assert_equal [ { "ownerSession" => [] } ], op["security"]
  end

  def test_the_landing_prompt_is_a_read_that_answers_text_or_a_refusal
    op = operation("get_landing_prompt")
    refute_includes parameter_names("get_landing_prompt"), "Idempotency-Key"
    assert_equal "#/components/schemas/LandingPrompt", response_ref("get_landing_prompt", "200")
    assert_equal "#/components/schemas/Refusal", response_ref("get_landing_prompt", "409")
    %w[401 404].each { |status| assert op["responses"].key?(status), "get_landing_prompt lacks #{status}" }
    prompt = schemas.fetch("LandingPrompt")
    assert_equal %w[check_interval_minutes text], prompt.fetch("required").sort
    assert_equal 20, prompt.dig("properties", "check_interval_minutes", "const")
    refused = { "code" => "invalid_state", "rule_id" => nil, "reason" => nil }
    assert validator("Refusal").valid?(refused)
    assert_equal %w[text check_interval_minutes].sort, ColumnsTest::NOT_COLUMNS.fetch("LandingPrompt").sort
  end

  def test_the_helper_request_carries_its_non_secret_inputs_and_its_progress
    request = schemas.fetch("HelperRequest")
    %w[params progress].each { |field| assert_includes request.fetch("required"), field }
    params = schemas.fetch("HelperRequestParams")
    assert_equal false, params["additionalProperties"]
    assert_empty params.fetch("properties").keys.grep(/\Aname\z|(\A|_)token\z/i)
    progress = schemas.fetch("HelperCheckProgress")
    assert_equal %w[waiting running waiting_for_sign_in waiting_for_install passed failed],
      progress.dig("properties", "state", "enum")
    assert_equal schemas.dig("HelperCheckResult", "properties", "check", "enum"), progress.dig("properties", "check", "enum")
    assert_equal "#/components/schemas/HelperCheckProgress",
      operation("report_request_progress").dig("requestBody", "content", "application/json", "schema", "$ref")
    assert_equal "#/components/schemas/CompletedOutcome", response_ref("report_request_progress", "200")
    assert operation("get_helper_request")["x-provisional"]
    assert_includes parameter_names("get_helper_request"), "wait"
  end

  def test_the_provisional_owner_reads_carry_as_of_seq
    PROVISIONAL_SHAPES.each do |id, component|
      assert_equal "#/components/schemas/#{component}", response_ref(id, "200"), id
      assert_includes schemas.fetch(component).fetch("required"), "as_of_seq", component
      assert_equal 0, schemas.fetch(component).dig("properties", "as_of_seq", "minimum"), component
    end
    %w[Board TaskPage].each do |component|
      assert_includes schemas.fetch(component).fetch("required"), "reviewer_seat_exists", component
    end
    assert_includes schemas.fetch("BoardTask").fetch("required"), "inbox_item"
    assert_includes schemas.fetch("TaskPage").fetch("required"), "inbox_items"
    assert_includes schemas.fetch("TaskPage").fetch("required"), "events"
    health = schemas.fetch("SystemHealth")
    # The Handoff milestone adds the backup's two fields (milestone 3 plan
    # HB-4), and the Rule checks milestone the waiting checks (milestone 4
    # plan RD-18).
    assert_equal %w[backup_last_ran_at backup_late helper_last_reported_at orchestrator queued_helper_requests ready_tasks
      sweep_last_ran_at sweep_late waiting_checks waiting_reviews], health.fetch("required").sort
    assert_includes health.dig("properties", "orchestrator", "enum"), "not_set_up"
  end

  # PRD Agent interface, the briefing call (Q-9): after a failed review it
  # also returns the reviewer's notes, outside the hash.
  def test_the_briefing_response_carries_the_notes_of_failed_reviews
    response = schemas.fetch("BriefingResponse")
    assert_includes response.fetch("required"), "review_notes"
    items = response.dig("properties", "review_notes", "items", "$ref")
    assert_equal "#/components/schemas/ReviewNote", items
    assert_equal %w[notes review_id round], schemas.fetch("ReviewNote").fetch("required").sort
    refute_includes schemas.fetch("Briefing").fetch("properties"), "review_notes", "the notes are outside the hash"
  end

  def test_add_credential_says_the_row_is_inserted_at_the_add_command
    description = schemas.fetch("AddCredentialRequest").fetch("description")
    refute_includes description, "The row is inserted when the helper reports every check passed."
    assert_includes description, "The row is inserted when this command runs"
  end

  def test_the_readme_says_public_covers_setup
    readme = File.read(File.join(CONTRACT_ROOT, "README.md"))
    row = readme.lines.find { |line| line.start_with?("| `public` |") }
    refute_nil row
    assert_includes row, "setup"
  end

  def test_trace_09_takes_one_task_through_one_failed_review_to_done_with_no_rules
    trace = Leverage::Contract.trace("09-core-loop-no-rules")
    assert_empty trace.dig("setup", "rules")
    assert_equal 2, trace.dig("setup", "credentials").size
    assert_equal %w[builder reviewer], trace.dig("setup", "seats").map { |seat| seat["role"] }.sort
    commands = trace.fetch("commands").map { |command| command["command"] }
    assert_equal %w[add_task complete_contract claim acknowledge_briefing start_criterion pass_criterion start_criterion
      pass_criterion submit claim_review acknowledge_review_briefing fail_review acknowledge_briefing start_criterion
      pass_criterion submit claim_review acknowledge_review_briefing pass_review], commands
    types = trace.fetch("commands").flat_map { |command| command["expect"]["events"].map { |event| event["type"] } }
    assert_equal 1, types.count("review.failed")
    assert_equal "task.done", (types - %w[cost.reported]).last
    refute types.any? { |type| type.start_with?("check.", "job.", "rule.", "inbox.") }
  end

  def test_trace_10_covers_releases_leases_the_round_limit_and_cancel
    trace = Leverage::Contract.trace("10-leases-no-rules")
    assert_empty trace.dig("setup", "rules")
    commands = trace.fetch("commands")
    names = commands.map { |command| command["command"] }
    %w[release builder_lease_expiry review_lease_expiry allow_another_round cancel].each { |name| assert_includes names, name }
    events = commands.flat_map { |command| command["expect"]["events"] }
    reasons = events.select { |event| event["type"] == "hold.opened" }.map { |event| event.dig("payload", "reason") }
    assert_equal %w[rounds_exceeded rounds_exceeded], reasons
    assert_equal 4, events.count { |event| event["type"] == "review.failed" }
    refusals = commands.filter_map { |command| command.dig("expect", "refusal", "code") }
    assert_includes refusals, "lease_expired"
    assert_equal "task_cancelled", refusals.last
    expiry = names.index("builder_lease_expiry")
    assert_equal "lease_expired", commands[expiry + 1].dig("expect", "refusal", "code"), "refused before any sweep"
    resume = names.index("allow_another_round")
    assert_equal "rounds_exceeded", commands[resume]["expect"]["events"].first.dig("payload", "reason")
  end
end
