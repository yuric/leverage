require_relative "contract_helper"

# api/contract/openapi.json: the agent, owner and helper interfaces in
# OpenAPI 3.1. Every assertion reads registry.json, never a file another
# part of the contract writes.
class OpenapiTest < Minitest::Test
  include ContractTestHelpers

  HTTP_METHODS = %w[get post put patch delete].freeze
  TOKEN_WORD = /(\A|_)token(_hash)?\z|secret|password|keychain|settings_folder/i
  # The only components that may carry a secret, once, in the response that
  # issues it (IF-15, IF-16, IF-17). A stored command outcome never does.
  ONE_TIME_RESPONSES = %w[SeatTokenPickup SeatConnected HelperTokenIssued OwnerSession].freeze
  # The operation that returns each one, and the token property it carries.
  ONE_TIME_OPERATIONS = {
    "issue_seat_token" => %w[SeatTokenPickup seat_token], "connect_seat" => %w[SeatConnected seat_token],
    "issue_helper_token" => %w[HelperTokenIssued helper_token], "sign_in_owner" => %w[OwnerSession session_token]
  }.freeze
  # The owner reads whose shapes wait for track F's queries (IF-18). The
  # events tail and the Needs you list are stable.
  PROVISIONAL_READS = %w[
    get_board get_task list_decisions list_seats list_projects list_rules list_credentials get_system_health
  ].freeze

  def doc = Leverage::Contract.openapi
  def schemas = doc.fetch("components").fetch("schemas")

  def operations
    doc.fetch("paths").flat_map do |path, item|
      item.select { |method, _| HTTP_METHODS.include?(method) }.map { |method, op| [ path, method, op ] }
    end
  end

  def deref(node)
    node = deref_ref(node.fetch("$ref")) while node.is_a?(Hash) && node.key?("$ref")
    node
  end

  def deref_ref(ref)
    assert ref.start_with?("#/components/"), "only internal $refs are allowed: #{ref}"
    ref.delete_prefix("#/").split("/").reduce(doc) { |node, key| node.fetch(key) }
  end

  # Every node (hash) of the document with the path to it.
  def each_node(node = doc, trail = [], &block)
    case node
    when Hash
      yield node, trail
      node.each { |key, value| each_node(value, trail + [ key ], &block) }
    when Array
      node.each_with_index { |value, index| each_node(value, trail + [ index ], &block) }
    end
  end

  def operation(operation_id)
    operations.find { |_, _, op| op["operationId"] == operation_id }&.last || flunk("no operation #{operation_id}")
  end

  def json_schema(media_holder)
    deref(media_holder).fetch("content").fetch("application/json").fetch("schema")
  end

  def response_schema(operation_id, status)
    json_schema(operation(operation_id).fetch("responses").fetch(status))
  end

  def request_schema(operation_id)
    json_schema(operation(operation_id).fetch("requestBody"))
  end

  def property(component, name)
    deref(schemas.fetch(component).fetch("properties").fetch(name))
  end

  # The enum behind a property: through $ref, nullable anyOf and arrays.
  def enum_of(component, name)
    node = deref(schemas.fetch(component).fetch("properties").fetch(name))
    node = deref(node.fetch("items")) if node["items"]
    node = deref(node["anyOf"].find { |branch| branch["type"] != "null" }) if node["anyOf"]
    node.fetch("enum").compact
  end

  # Every schema reachable from a component, following $ref.
  def reachable(name, seen = {})
    return seen if seen.key?(name)

    seen[name] = schemas.fetch(name)
    each_node(seen[name]) do |node, _|
      next unless node["$ref"]

      target = node["$ref"].delete_prefix("#/components/schemas/")
      reachable(target, seen) if schemas.key?(target)
    end
    seen
  end

  def property_names(schema)
    names = []
    each_node(schema) { |node, _| names.concat(node["properties"].keys) if node["properties"].is_a?(Hash) }
    names
  end

  def test_is_a_valid_openapi_3_1_document
    assert_match(/\A3\.1\.\d+\z/, doc.fetch("openapi"))
    assert_equal [], JSONSchemer.openapi(doc).validate.map { |error| error.fetch("error") }.first(5)
    assert JSONSchemer.openapi(doc).valid?
  end

  def test_the_operations_are_exactly_the_registry_operations
    expected = registry.fetch("operations").map do |op|
      [ op["operation_id"], op["method"], op["path"], op["tag"], op["caller"], op["commands"] ]
    end
    actual = operations.map do |path, method, op|
      [ op["operationId"], method.upcase, path, op["tags"]&.first, op["x-leverage-caller"], op["x-leverage-command"] ]
    end
    assert_equal expected.sort, actual.sort
    assert_empty duplicates(actual.map(&:first))
    operations.each { |_, _, op| assert_equal 1, op["tags"].size, op["operationId"] }
  end

  def test_every_operation_has_a_summary_and_snake_case_names
    operations.each do |_, _, op|
      assert_match SNAKE_CASE, op["operationId"]
      refute_empty op["summary"].to_s, op["operationId"]
    end
    schemas.each_key { |name| assert_match(/\A[A-Z][A-Za-z0-9]*\z/, name) }
    each_node do |node, trail|
      next unless node["properties"].is_a?(Hash) && trail.last != "properties"

      node["properties"].each_key { |key| assert_match SNAKE_CASE, key, trail.join("/") }
    end
  end

  def test_every_path_parameter_is_documented
    operations.each do |path, _, op|
      documented = op.fetch("parameters", []).map { |parameter| deref(parameter) }.select { |p| p["in"] == "path" }
      assert_equal path.scan(/\{(\w+)\}/).flatten.sort, documented.map { |p| p["name"] }.sort, op["operationId"]
      documented.each { |parameter| assert parameter["required"], op["operationId"] }
    end
  end

  def test_every_mutating_operation_takes_the_idempotency_key_and_documents_200_202_409
    mutating = operations.select { |_, method, _| method == "post" }
    refute_empty mutating
    mutating.each do |_, _, op|
      headers = op.fetch("parameters", []).map { |parameter| deref(parameter) }.select { |p| p["in"] == "header" }
      assert_equal [ "Idempotency-Key" ], headers.map { |h| h["name"] }, op["operationId"]
      assert headers.first["required"], op["operationId"]
      %w[200 202 409].each { |status| assert op["responses"].key?(status), "#{op["operationId"]} lacks #{status}" }
    end
    operations.reject { |_, method, _| method == "post" }.each do |_, _, op|
      names = op.fetch("parameters", []).map { |parameter| deref(parameter)["name"] }
      refute_includes names, "Idempotency-Key", op["operationId"]
    end
  end

  def test_pending_and_refused_answers_have_their_own_bodies
    %w[202 409].each do |status|
      operations.select { |_, method, _| method == "post" }.each do |_, _, op|
        schema = json_schema(op["responses"].fetch(status))
        assert_equal({ "$ref" => status == "202" ? "#/components/schemas/PendingOutcome" : "#/components/schemas/RefusedOutcome" },
          schema, op["operationId"])
      end
    end
  end

  def test_transport_errors_are_outside_the_registry
    codes = schemas.fetch("TransportError").dig("properties", "error", "properties", "code", "enum")
    assert_equal %w[malformed unauthenticated not_found key_reused invalid], codes
    assert_empty codes & registry.fetch("refusals").map { |refusal| refusal["code"] }
    operations.each do |path, method, op|
      responses = op.fetch("responses")
      assert responses.key?("401"), "#{op["operationId"]} lacks 401" unless op["x-leverage-caller"] == "public"
      assert responses.key?("404"), "#{op["operationId"]} lacks 404" if path.include?("{")
      if method == "post"
        assert responses.key?("400"), "#{op["operationId"]} lacks 400"
        assert responses.key?("422"), "#{op["operationId"]} lacks 422"
      end
    end
  end

  def test_the_refusal_codes_are_the_registry_refusals_in_order
    assert_equal registry.fetch("refusals").sort_by { |r| r["precedence"] || 99 }.map { |r| r["code"] },
      enum_of("Refusal", "code")
    assert_equal %w[code rule_id reason], schemas.fetch("Refusal").fetch("required")
  end

  def test_the_outcome_body_has_the_five_fields_of_if_4
    outcome = schemas.fetch("CommandOutcome")
    assert_equal %w[key command outcome result refusal], outcome.fetch("required")
    assert_equal registry.dig("lists", "command_outcomes"), enum_of("CommandOutcome", "outcome")
    assert_equal registry.fetch("commands"), enum_of("CommandOutcome", "command")
    assert_equal({ "$ref" => "#/components/schemas/CommandOutcome" }, response_schema("get_command", "200"))
    assert_equal({ "$ref" => "#/components/schemas/CommandOutcome" }, response_schema("get_owner_command", "200"))
  end

  def test_get_next_answers_one_item_with_the_registry_kinds_in_precedence_order
    assert_equal registry.fetch("next_kinds"), enum_of("NextItem", "kind")
    assert_equal({ "$ref" => "#/components/schemas/NextItem" }, response_schema("get_next", "200"))
    assert_includes schemas.fetch("NextItem").fetch("properties"), "review_id"
    wait = operation("get_next").fetch("parameters").map { |p| deref(p) }.find { |p| p["name"] == "wait" }
    assert_equal({ "type" => "integer", "minimum" => 0, "maximum" => 30, "default" => 30 }, wait["schema"])
  end

  def test_the_events_tail_and_the_inbox_are_stable_reads_with_a_cursor
    { "list_events" => "EventsPage", "list_inbox" => "InboxPage" }.each do |operation_id, page|
      assert_equal({ "$ref" => "#/components/schemas/#{page}" }, response_schema(operation_id, "200"))
      refute operation(operation_id)["x-provisional"], operation_id
      assert_includes schemas.fetch(page).fetch("required"), "next_after_seq"
      params = operation(operation_id).fetch("parameters").map { |p| deref(p) }.to_h { |p| [ p["name"], p["schema"] ] }
      assert_equal 0, params.fetch("after_seq")["minimum"]
      assert_equal 30, params.fetch("wait")["maximum"]
    end
    limit = operation("list_events").fetch("parameters").map { |p| deref(p) }.find { |p| p["name"] == "limit" }
    assert_equal 100, limit["schema"]["default"]
    assert_equal 500, limit["schema"]["maximum"]
    assert_equal registry.fetch("event_types").map { |e| e["type"] }, enum_of("Event", "type")
    assert_equal %w[id workspace_id seq at effective_at type schema_version actor_kind actor_id project_id task_id round
      subject_kind subject_id cause_id command_id payload].sort, schemas.fetch("Event").fetch("required").sort
    assert_equal registry.dig("lists", "inbox_choices"), enum_of("InboxItem", "choices")
    assert_equal registry.fetch("needs_you_items"), enum_of("InboxItem", "kind")
  end

  def test_the_other_owner_reads_are_provisional
    owner_reads = operations.select { |_, method, op| method == "get" && op["tags"] == [ "owner" ] }.map { |_, _, op| op["operationId"] }
    provisional = operations.select { |_, _, op| op["x-provisional"] }.map { |_, _, op| op["operationId"] }
    assert_equal PROVISIONAL_READS.sort, provisional.sort
    stable = owner_reads - provisional
    assert_equal %w[get_owner_command list_events list_inbox], stable.sort
  end

  def test_health_is_infrastructure_outside_the_agent_calls
    op = operation("get_health")
    assert_equal [ "infrastructure" ], op["tags"]
    assert_equal [], op["security"]
    assert_equal %w[status version], schemas.fetch("Health").fetch("required")
  end

  def test_security_schemes_follow_the_caller
    schemes = doc.dig("components", "securitySchemes")
    assert_equal %w[helperBearer ownerSession seatBearer], schemes.keys.sort
    schemes.each_value { |scheme| assert_equal({ "type" => "http", "scheme" => "bearer" }, scheme.slice("type", "scheme")) }
    operations.each do |_, _, op|
      expected =
        if op["operationId"] == "sign_in_owner" || op["x-leverage-caller"] == "public" then []
        else [ { { "agent" => "seatBearer", "owner" => "ownerSession", "helper" => "helperBearer" }.fetch(op["tags"].first) => [] } ]
        end
      assert_equal expected, op["security"], op["operationId"]
    end
  end

  def test_enums_equal_their_registry_lists
    lists = registry.fetch("lists")
    providers = registry.fetch("credential_providers").map { |p| p["provider"] }
    {
      [ "TaskSummary", "state" ] => lists["task_states"], [ "TaskSummary", "priority" ] => lists["priorities"],
      [ "Criterion", "state" ] => lists["criterion_states"], [ "Criterion", "kind" ] => lists["criterion_kinds"],
      [ "Action", "state" ] => lists["action_states"], [ "Action", "kind" ] => lists["action_kinds"],
      [ "Evidence", "kind" ] => lists["evidence_kinds"], [ "Review", "verdict" ] => lists["review_verdicts"],
      [ "GiveVerdictRequest", "verdict" ] => lists["review_verdicts"],
      [ "Question", "outcome" ] => lists["question_outcomes"], [ "Question", "basis" ] => lists["question_bases"],
      [ "BriefEntry", "kind" ] => lists["brief_entry_kinds"],
      [ "Seat", "role" ] => lists["seat_roles"], [ "ConnectSeatRequest", "role" ] => lists["seat_roles"],
      [ "Seat", "provider" ] => providers, [ "Seat", "run_state" ] => lists["seat_run_states"],
      [ "Credential", "provider" ] => providers, [ "Credential", "kind" ] => lists["credential_kinds"],
      [ "Credential", "state" ] => lists["credential_states"],
      [ "AddCredentialRequest", "provider" ] => providers, [ "AddCredentialRequest", "kind" ] => lists["credential_kinds"],
      [ "CredentialReading", "state" ] => lists["reading_states"], [ "Figure", "kind" ] => lists["figure_kinds"],
      [ "Figure", "window" ] => lists["limit_windows"], [ "LimitReport", "window" ] => lists["limit_windows"],
      [ "Reset", "kind" ] => lists["reset_kinds"],
      [ "HelperRequest", "kind" ] => lists["helper_request_kinds"], [ "HelperRequest", "state" ] => lists["helper_request_states"],
      [ "InboxItem", "state" ] => lists["inbox_states"], [ "InboxItem", "about_kind" ] => lists["inbox_about_kinds"],
      [ "Event", "actor_kind" ] => lists["actor_kinds"], [ "Event", "subject_kind" ] => lists["event_subject_kinds"],
      [ "RuleVersion", "hook" ] => registry["hooks"], [ "RuleVersion", "kind" ] => lists["rule_kinds"],
      [ "RuleVersion", "checker" ] => lists["checkers"], [ "RuleVersion", "on_fail" ] => lists["on_fail"],
      [ "RuleVersion", "route" ] => lists["routes"], [ "RuleVersion", "origin" ] => lists["rule_origins"],
      [ "RuleScope", "kind" ] => lists["scope_kinds"], [ "RuleScope", "action_kinds" ] => lists["action_kinds"],
      [ "ChangeTaskPriorityRequest", "priority" ] => lists["priorities"],
      [ "Hold", "reason" ] => registry["hold_reasons"].map { |h| h["reason"] },
      [ "BoardTask", "hold_reasons" ] => registry["hold_reasons"].map { |h| h["reason"] },
      [ "ClaimJobResult", "kind" ] => registry["job_kinds"].map { |k| k["kind"] },
      [ "ReleaseTaskRequest", "reason" ] => registry["release_reasons"].select { |r| r["chosen_by"] == "seat" }.map { |r| r["reason"] }
    }.each do |(component, name), expected|
      assert_equal expected, enum_of(component, name), "#{component}.#{name}"
    end
    assert_equal lists["task_states"].values_at(0, 1), enum_of("AddTaskRequest", "state")
    assert_equal registry["custom_rule_hooks"], enum_of("AddRuleRequest", "hook")
  end

  def test_the_job_components_named_by_the_registry_exist
    registry.fetch("job_kinds").each do |job|
      assert schemas.key?(job["input_component"]), job["input_component"]
      assert schemas.key?(job["result_component"]), job["result_component"]
    end
    inputs = schemas.dig("ClaimJobResult", "properties", "input", "oneOf").map { |ref| ref["$ref"].split("/").last }
    assert_equal registry["job_kinds"].map { |job| job["input_component"] }, inputs
    results = schemas.dig("JobResultRequest", "properties", "result", "oneOf").map { |ref| ref["$ref"].split("/").last }
    assert_equal registry["job_kinds"].map { |job| job["result_component"] }, results
    assert_equal registry["job_kinds"].map { |job| job["kind"] }.size, registry["job_kinds"].map { |job| job["input_component"] }.uniq.size
  end

  def test_job_shapes_have_one_home_and_every_result_carries_tokens_and_spend
    assert_equal %w[reason result], schemas.fetch("RuleCheckJobResult").fetch("required").sort
    assert_equal %w[passed failed not_applicable], enum_of("RuleCheckJobResult", "result")
    assert_empty enum_of("RuleCheckJobResult", "result") - registry["check_results"]
    assert_equal %w[answered passed_on], enum_of("QuestionJobResult", "outcome")
    assert_empty enum_of("QuestionJobResult", "outcome") - registry.dig("lists", "question_outcomes")
    assert_equal %w[record decision], enum_of("QuestionJobResult", "basis")
    assert_equal %w[approve stop pass_to_owner], enum_of("ApprovalJobResult", "decision")
    assert_equal %w[rule_check_id attempt_number rule_version_id hook task_id project_id inputs].sort,
      schemas.fetch("RuleCheckJobInput").fetch("required").sort
    assert_equal %w[question_id task_id project_id].sort, schemas.fetch("QuestionJobInput").fetch("required").sort
    assert_equal %w[action_id rule_check_id task_id project_id].sort, schemas.fetch("ApprovalJobInput").fetch("required").sort
    assert_equal %w[task_id project_id brief_version].sort, schemas.fetch("ContractDraftJobInput").fetch("required").sort
    assert_equal registry["hooks"], enum_of("RuleCheckJobInput", "hook")
    assert_equal %w[result tokens spend].sort, schemas.fetch("JobResultRequest").fetch("required").sort
    assert_equal({ "$ref" => "#/components/schemas/JobResultRequest" }, request_schema("submit_job_result"))
    assert_equal "#/components/schemas/CompleteContractRequest", schemas.fetch("ContractDraftJobResult").fetch("$ref")
    assert_equal [ "$ref" ], schemas.fetch("ContractDraftJobResult").keys - %w[description]
    assert_equal({ "$ref" => "#/components/schemas/CompleteContractRequest" }, request_schema("complete_contract"))
  end

  # ARCHITECTURE: every changing call answers one outcome body. A one-time
  # token is the result of the first answer for its key; a repeat of the key
  # answers the same envelope with a *Repeated result that has no token.
  def test_one_time_tokens_come_in_the_outcome_envelope_and_a_repeat_drops_them
    openapi = JSONSchemer.openapi(doc)
    ONE_TIME_OPERATIONS.each do |operation_id, (component, token)|
      envelope = "#{component}Completed"
      assert_equal({ "$ref" => "#/components/schemas/#{envelope}" }, response_schema(operation_id, "200"), operation_id)
      assert_includes operation(operation_id)["responses"]["200"]["description"], "repeat", operation_id
      body = schemas.fetch(envelope)
      assert_equal %w[command key outcome refusal result], body.fetch("required").sort, envelope
      assert_equal "completed", body.dig("properties", "outcome", "const"), envelope
      assert_equal [ "#/components/schemas/#{component}", "#/components/schemas/#{component}Repeated" ],
        body.dig("properties", "result", "oneOf").map { |branch| branch["$ref"] }, envelope
      assert_includes schemas.fetch(component).fetch("required"), token, component
      repeated = schemas.fetch("#{component}Repeated")
      refute_includes repeated.fetch("properties"), token, "#{component}Repeated"
      assert_equal true, repeated.dig("properties", "repeated", "const"), "#{component}Repeated"

      validator = openapi.ref("#/components/schemas/#{envelope}")
      first = schemas.fetch(component).fetch("examples").first
      again = schemas.fetch("#{component}Repeated").fetch("examples").first
      wrap = ->(result) { { "key" => "k", "command" => registry["operations"].find { |op| op["operation_id"] == operation_id }["commands"].first, "outcome" => "completed", "result" => result, "refusal" => nil } }
      assert validator.valid?(wrap.call(first)), "#{envelope}: the first answer"
      assert validator.valid?(wrap.call(again)), "#{envelope}: a repeat"
      refute validator.valid?(wrap.call(first.except(token))), "#{envelope}: a first answer without its token"
    end
    connected = JSONSchemer.openapi(doc).ref("#/components/schemas/SeatConnectedCompleted")
    app_run = { "key" => "k", "command" => "connect_seat", "outcome" => "completed", "refusal" => nil,
                "result" => { "seat_id" => uuid(1), "seat_token" => nil } }
    assert connected.valid?(app_run), "a seat the app runs gets seat_token null"
    refute connected.valid?(app_run.merge("result" => { "seat_id" => uuid(1), "seat_token" => nil, "repeated" => true }))
  end

  def test_the_seat_token_is_returned_once_and_never_stored
    pickup = operation("issue_seat_token")
    assert_equal({ "$ref" => "#/components/schemas/SeatTokenPickupCompleted" }, json_schema(pickup["responses"].fetch("200")))
    assert_includes schemas.fetch("SeatTokenPickup").fetch("properties"), "seat_token"
    assert_includes pickup["description"], "never stored"
    %w[HelperRequest CommandOutcome PendingOutcome RefusedOutcome CompletedOutcome TransportError Refusal].each do |name|
      names = property_names(reachable(name).values)
      assert_empty names.grep(TOKEN_WORD), "#{name} must have no token property"
    end
    operations.each do |_, method, op|
      next unless method == "post"

      refs = [ op["responses"].fetch("200") ].map { |response| json_schema(response)["$ref"] }.compact.map { |ref| ref.split("/").last }
      one_time = refs & ONE_TIME_RESPONSES.map { |name| "#{name}Completed" }
      allowed = %w[issue_seat_token connect_seat issue_helper_token sign_in_owner]
      assert_equal allowed.include?(op["operationId"]), !one_time.empty?, op["operationId"]
    end
    # Only the four one-time responses may name a token at all (C17).
    (schemas.keys - ONE_TIME_RESPONSES).each do |name|
      names = property_names(schemas.fetch(name)).grep(TOKEN_WORD)
      assert_empty names - (name == "SignInRequest" ? %w[password] : []), "#{name} names a secret: #{names}"
    end
  end

  def test_nothing_the_owner_or_helper_sends_can_carry_a_provider_secret
    %w[AddCredentialRequest HelperRequestResult CredentialReading LimitReport SignOutReport].each do |name|
      assert_empty property_names(reachable(name).values).grep(TOKEN_WORD), name
    end
    assert_empty property_names(reachable("Credential").values).grep(/secret|keychain|settings_folder|token/i)
  end

  def test_the_credential_reading_and_the_two_reports_have_the_contract_shape
    assert_equal registry.dig("lists", "reading_states"), enum_of("CredentialReading", "state")
    assert_equal %w[credential_id observed_at state tool_version figures resets].sort,
      schemas.fetch("CredentialReading").fetch("required").sort
    assert_equal %w[label kind window percent_used reset_at value].sort, schemas.fetch("Figure").fetch("required").sort
    assert_equal %w[count kind expires_at].sort, schemas.fetch("Reset").fetch("required").sort
    assert_equal %w[credential_id seat_id task_id review_id job_id window reset_at observed_at tool_version].sort,
      schemas.fetch("LimitReport").fetch("required").sort
    assert_equal %w[credential_id seat_id task_id review_id job_id observed_at tool_version].sort,
      schemas.fetch("SignOutReport").fetch("required").sort
    assert_equal({ "$ref" => "#/components/schemas/LimitReport" }, request_schema("report_limit"))
    assert_equal({ "$ref" => "#/components/schemas/SignOutReport" }, request_schema("report_signed_out"))
    assert_equal({ "$ref" => "#/components/schemas/CredentialReading" }, request_schema("report_reading"))
    assert_equal({ "$ref" => "#/components/schemas/HelperRequestResult" }, deref(request_schema("report_request_result")).dig("properties", "result"))
  end

  def test_a_limit_report_names_exactly_one_of_task_review_and_job
    report = JSONSchemer.openapi(doc).ref("#/components/schemas/LimitReport")
    base = { "credential_id" => uuid(1), "seat_id" => uuid(2), "task_id" => nil, "review_id" => nil, "job_id" => nil,
            "window" => "five_hour", "reset_at" => nil, "observed_at" => "2026-01-01T00:00:00Z", "tool_version" => "0.0.0" }
    assert report.valid?(base.merge("task_id" => uuid(3)))
    assert report.valid?(base.merge("job_id" => uuid(3)))
    refute report.valid?(base)
    refute report.valid?(base.merge("task_id" => uuid(3), "job_id" => uuid(4)))
    refute report.valid?(base.merge("task_id" => uuid(3), "raw_reply" => "x"))
  end

  def test_the_helper_calls_are_the_if_15_paths
    helper = operations.select { |_, _, op| op["tags"] == [ "helper" ] }.map { |path, method, _| "#{method.upcase} #{path}" }
    assert_equal [
      "GET /v1/helper/next", "POST /v1/helper/requests/{id}/result", "POST /v1/helper/requests/{id}/seat-token",
      "POST /v1/helper/seats/{id}/run-started", "POST /v1/helper/seats/{id}/run-stopped",
      "POST /v1/helper/credentials/{id}/limit-reached", "POST /v1/helper/credentials/{id}/signed-out",
      "POST /v1/helper/credentials/{id}/readings"
    ].sort, helper.sort
    assert_equal registry.dig("lists", "helper_request_kinds"), enum_of("HelperRequest", "kind")
  end

  def test_the_owner_issues_the_helper_token_and_signs_in
    assert_equal({ "$ref" => "#/components/schemas/HelperTokenIssuedCompleted" }, response_schema("issue_helper_token", "200"))
    assert_equal({ "$ref" => "#/components/schemas/OwnerSessionCompleted" }, response_schema("sign_in_owner", "200"))
    assert_equal %w[email_address password].sort, schemas.fetch("SignInRequest").fetch("required").sort
  end

  # PRD Outward actions: rework "reopens the criteria the owner names and the
  # review criterion", so the owner's call names them.
  # PRD Data model, credentials: masked label, plan and account email, and
  # the model, effort and strength rank used on handoff. The Mac app makes
  # the masked label; the helper's add checks and Verify read plan and email.
  # None of them is ever in an event payload.
  def test_requests_carry_every_credential_field_the_server_keeps
    add = schemas.fetch("AddCredentialRequest").fetch("properties")
    %w[masked_label model effort].each { |name| assert_equal [ "string", "null" ], add.fetch(name)["type"], name }
    assert_equal [ "integer", "null" ], add.fetch("strength_rank")["type"]
    assert_includes schemas.fetch("AddCredentialRequest").fetch("required"), "strength_rank"
    result = schemas.fetch("HelperRequestResult").fetch("properties")
    %w[plan account_email].each { |name| assert_equal [ "string", "null" ], result.fetch(name)["type"], name }
    registry["event_types"].each do |entry|
      entry["schema_versions"].each do |version|
        names = property_names(Leverage::Contract.payload_schema(entry["type"], version))
        assert_empty names & %w[masked_label plan account_email], entry["type"]
      end
    end
  end

  # L588, L688: the server picks the credential a claim runs on, and the run
  # points the tool at it; the claim result says which, and with what model.
  def test_claim_results_name_the_credential_and_model_the_claim_runs_on
    model = Leverage::Contract.payload_schema("task.claimed", 1).dig("properties", "model")
    %w[ClaimTaskResult ClaimReviewResult ClaimJobResult].each do |name|
      schema = schemas.fetch(name)
      assert_includes schema.fetch("required"), "credential_id", name
      assert_includes schema.fetch("required"), "model", name
      assert_equal [ "string", "null" ], schema.dig("properties", "credential_id", "type"), name
      assert_equal "uuid", schema.dig("properties", "credential_id", "format"), name
      assert_equal model["pattern"], schema.dig("properties", "model", "pattern"), name
    end
  end

  def test_return_for_rework_names_the_criteria_to_reopen
    schema = deref(request_schema("return_for_rework"))
    assert_includes schema.fetch("required"), "criterion_ids"
    ids = deref(schema.fetch("properties").fetch("criterion_ids"))
    assert_equal "array", ids.fetch("type")
    assert_equal "uuid", deref(ids.fetch("items")).fetch("format")
  end

  def test_json_field_names_are_the_data_model_column_names
    columns = {
      "TaskSummary" => %w[project_id title goal state round holder_seat_id builder_seat_id lease_due_at minimum_strength_rank
        contract_version budget_cap spent work_reference priority],
      "Criterion" => %w[task_id position text kind state passed_at],
      "Review" => %w[task_id round reviewer_seat_id lease_due_at verdict failed_criteria notes],
      "Question" => %w[task_id text assumption blocking outcome answer basis],
      "Seat" => %w[name provider model effort role strength_rank credential_id enabled paused last_polled_at],
      "Credential" => %w[kind provider name masked_label plan account_email state limited_until position model effort
        strength_rank last_verified_at],
      "Project" => %w[name goal budget spent paused],
      "InboxItem" => %w[kind about_kind about_id hold_id credential_id choices facts state opened_at resolved_at],
      "HelperRequest" => %w[kind seat_id credential_id state requested_at picked_up_at finished_at result],
      "Hold" => %w[task_id project_id reason rule_id credential_id opened_at closed_at]
    }
    columns.each do |component, names|
      assert_empty names - schemas.fetch(component).fetch("properties").keys, component
    end
  end

  def test_lint_no_keyword_a_generator_is_likely_to_reject
    each_node do |node, trail|
      %w[$dynamicRef $dynamicAnchor if then else unevaluatedProperties unevaluatedItems].each do |keyword|
        next if trail.last == "properties" || trail.last == "examples" || trail.include?("examples")

        refute node.key?(keyword), "#{keyword} at #{trail.join("/")}"
      end
      next unless node["$ref"]

      assert node["$ref"].start_with?("#/components/"), "external $ref at #{trail.join("/")}"
      deref_ref(node["$ref"])
    end
  end

  def test_every_component_is_used_and_every_object_component_is_closed
    referenced = []
    each_node { |node, _| referenced << node["$ref"].split("/").last if node["$ref"] }
    orphans = schemas.keys - referenced.uniq
    assert_empty orphans, "components nothing refers to"
    schemas.each do |name, schema|
      next unless schema["properties"]

      assert_equal false, schema["additionalProperties"], "#{name} is not closed" unless schema["x-open"]
    end
  end

  def test_every_object_component_has_an_example_and_every_example_validates
    openapi = JSONSchemer.openapi(doc)
    schemas.each do |name, schema|
      examples = schema["examples"]
      if schema["properties"] || schema["allOf"]
        refute_nil examples, "#{name} has no examples"
        refute_empty examples, "#{name} has no examples"
      end
      Array(examples).each do |example|
        errors = openapi.ref("#/components/schemas/#{name}").validate(example).map { |e| e.fetch("error") }
        assert_empty errors, "#{name} example #{example.inspect[0, 200]}"
      end
    end
  end

  def test_an_unknown_property_and_a_wrong_enum_value_are_rejected
    outcome = JSONSchemer.openapi(doc).ref("#/components/schemas/RefusedOutcome")
    example = schemas.fetch("RefusedOutcome").fetch("examples").first
    assert outcome.valid?(example)
    refute outcome.valid?(example.merge("token" => "x"))
    refute outcome.valid?(example.merge("refusal" => example["refusal"].merge("code" => "teapot")))
    refute outcome.valid?(example.merge("outcome" => "completed"))
  end

  private

  def uuid(number) = format("00000000-0000-4000-8000-%012d", number)
end
