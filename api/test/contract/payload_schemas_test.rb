require_relative "contract_helper"

# payloads/<type>.v<n>.json: one schema per registered (type, version), each
# a closed object of ids, numbers and short fixed values (PRD, Event log,
# principle 7), with the fields replay needs (PRD, What the replay test
# rebuilds). The rules are functions of PayloadRules, so the negative
# fixtures in fixtures/bad_payloads/ are rejected by the same code that
# accepts the real files.
module PayloadRules
  PAYLOADS = File.join(ContractTestHelpers::CONTRACT_ROOT, "payloads")

  CLOSED_FORMATS = %w[uuid date-time].freeze
  # A SHA-256 digest in lower-case hex is a code, not text.
  DIGEST_PATTERN = "^[0-9a-f]{64}$".freeze
  NON_STRING_TYPES = %w[integer number boolean null array object].freeze

  # String properties allowed without an enum, const or format. Each must
  # still carry a `pattern` and a `maxLength`. Reviewed and cited: the PRD
  # says the payload carries "the model actually used" next to the
  # credential's id (Credentials, Handoff, What is recorded), and a model
  # name is not a closed list.
  OPEN_STRINGS = {
    [ "task.claimed", "model" ] => "PRD Credentials, What is recorded",
    [ "review.started", "model" ] => "PRD Credentials, What is recorded",
    [ "job.claimed", "model" ] => "PRD Credentials, What is recorded",
    [ "credential.switched", "model" ] => "PRD Credentials, What is recorded"
  }.freeze

  # (type, property) => [vocabulary, relation]. The property's enum, less
  # null, must equal (or be a subset of) the registry vocabulary.
  ENUM_LISTS = {
    [ "task.created", "state" ] => [ "lists.task_states", :subset ],
    [ "task.changed", "priority" ] => [ "lists.priorities", :equal ],
    [ "task.released", "reason" ] => [ "release_reasons", :equal ],
    [ "evidence.attached", "kind" ] => [ "lists.evidence_kinds", :equal ],
    [ "hold.opened", "reason" ] => [ "hold_reasons", :equal ],
    [ "hold.closed", "reason" ] => [ "hold_reasons", :equal ],
    [ "question.answered", "basis" ] => [ "lists.question_bases", :equal ],
    [ "check.queued", "hook" ] => [ "hooks", :equal ],
    [ "check.finished", "hook" ] => [ "hooks", :equal ],
    [ "check.finished", "result" ] => [ "check_results", :equal ],
    [ "check.finished", "effect" ] => [ "policy_effects", :equal ],
    [ "check.queued", "subject_kind" ] => [ "lists.check_subject_kinds", :equal ],
    [ "check.finished", "subject_kind" ] => [ "lists.check_subject_kinds", :equal ],
    [ "job.queued", "kind" ] => [ "job_kinds", :equal ],
    [ "inbox.opened", "kind" ] => [ "needs_you_items", :equal ],
    [ "inbox.resolved", "choice" ] => [ "lists.inbox_choices", :equal ],
    [ "credential.limit_reached", "window" ] => [ "lists.limit_windows", :equal ]
  }.freeze

  # Every event that can open `wait_ready` carries its cause (plan SM-41;
  # PRD Steps and timing, rule 8: a step's cause is fixed when it opens,
  # and credential state is outside the replay).
  WAIT_CAUSE_TYPES = %w[
    task.ready task.released task.lease_expired review.failed task.reassigned
    task.returned_for_rework hold.closed check.finished
  ].freeze

  # The fields replay and the PRD's stated facts need, by type. Cited by
  # PRD section (What the replay test rebuilds = "Replay") and plan decision.
  REQUIRED_FIELDS = {
    # Replay: tasks.state; Add task lands in Imaginarium or Backlog.
    "task.created" => %w[state],
    # Replay: tasks.contract_version, tasks.minimum_strength_rank (the
    # contract sets it; decisions.md, Changes after merge), criteria.state,
    # actions.state (DB-19).
    "task.contract_changed" => %w[
      contract_version minimum_strength_rank added_criterion_ids reset_criterion_ids removed_criterion_ids
      added_action_ids removed_action_ids
    ],
    # Event types: "(priority, project, cap)" (P-8, SM-31).
    "task.changed" => %w[priority project_id budget_cap],
    # Replay: holder and builder; Credentials: the credential id and model.
    "task.claimed" => %w[seat_id credential_id model],
    # Event types: the release reason; replay of the wait_ready cause.
    "task.released" => %w[reason],
    # Agent interface: only whether the work reference changed.
    "task.submitted" => %w[work_reference_changed],
    # Replay: tasks.minimum_strength_rank (SM-9).
    "task.reassigned" => %w[minimum_strength_rank],
    # Replay: the holder after an owner rework (SM-7, DB-43).
    "task.returned_for_rework" => %w[lease_seat_id],
    "evidence.attached" => %w[criterion_id kind],
    "review.started" => %w[credential_id model],
    # Rework and escalation: the event records whether the builder got a
    # fresh lease (SM-7); the failed criteria or rule (SM-6, DB-18).
    "review.failed" => %w[lease_seat_id failed_criterion_ids failed_rule_check_id],
    # Replay: the holder when a waive lets the approval rule grant the lease
    # with no hold to close (SM-11, DB-43).
    "action.waived" => %w[lease_seat_id],
    # Holds: a reason and the rule or credential; wait_limit's subject (SM-41).
    "hold.opened" => %w[reason rule_id credential_id],
    # Replay: the holder after Offer task again (DB-43).
    "hold.closed" => %w[reason rule_id credential_id lease_seat_id],
    "question.asked" => %w[blocking],
    "question.answered" => %w[basis],
    # Replay: the holder after an approval or a delayed grant (SM-7, SM-8).
    "action.approved" => %w[lease_seat_id],
    "action.lease_granted" => %w[lease_seat_id],
    # Replay: the provisional holder and the check step's subject (DB-43,
    # SM-41); the rule_checks row's subject and input hash, which replay into
    # empty tables needs to insert it (L771, L782).
    "check.queued" => %w[hook rule_id rule_version_id attempt_number job_id blocking claimant_seat_id pending_transition_id
                         action_id subject_kind subject_id input_hash],
    # Replay: rule_checks.result; the rule a step's cause names (DB-32); the
    # row's identity, since an app check writes no check.queued (L771).
    "check.finished" => %w[hook rule_id rule_version_id result effect subject_kind subject_id input_hash],
    # Replay: rules.enabled and the current version.
    "rule.created" => %w[rule_version_id version enabled],
    "rule.changed" => %w[rule_version_id version],
    "rule.reverted" => %w[rule_version_id version],
    "job.queued" => %w[kind],
    "job.claimed" => %w[credential_id model],
    # Replay: projects.spent.
    "cost.reported" => %w[tokens spend],
    "project.budget_changed" => %w[budget],
    "brief.changed" => %w[brief_version],
    "inbox.opened" => %w[kind],
    "inbox.resolved" => %w[choice],
    # Recovery time ends at an event by the seat that continues (Handoff).
    "credential.limit_reached" => %w[seat_id review_id job_id window reset_at],
    "credential.signed_out" => %w[seat_id review_id job_id],
    "credential.switched" => %w[from_credential_id model seat_id review_id job_id]
  }.freeze

  module_function

  def file_for(type, version)
    File.join(PAYLOADS, "#{type}.v#{version}.json")
  end

  # Each rule returns a list of error strings for one (type, schema).
  def rules
    %i[meta valid_schema examples_validate all_required closed_strings ids_are_uuid
       credential_by_id_only enum_matches_list enum_from_registry required_fields wait_cause]
  end

  def errors(rule, type, schema, registry)
    send(:"check_#{rule}", type, schema, registry)
  end

  def check_meta(_type, schema, _registry)
    meta = JSONSchemer.schema(Leverage::Contract.meta_schema("payload"))
    meta.validate(schema).map { |error| error.fetch("error") }
  end

  def check_valid_schema(_type, schema, _registry)
    JSONSchemer.valid_schema?(schema) ? [] : [ "not a valid 2020-12 schema" ]
  end

  def check_examples_validate(_type, schema, _registry)
    schemer = JSONSchemer.schema(schema)
    Array(schema["examples"]).each_with_index.flat_map do |example, index|
      schemer.validate(example).map { |error| "example #{index}: #{error.fetch("error")}" }
    end
  end

  # A field that may be absent in fact is required and null (README).
  def check_all_required(_type, schema, _registry)
    missing = schema.fetch("properties", {}).keys - Array(schema["required"])
    missing.map { |name| "#{name} is not required" }
  end

  def check_closed_strings(type, schema, _registry)
    each_property(schema).flat_map do |path, sub|
      next [] unless may_be_string?(sub)
      next [] if closed?(sub)

      if OPEN_STRINGS.key?([ type, path ])
        sub["pattern"] && sub["maxLength"] ? [] : [ "#{path}: an open string needs a pattern and a maxLength" ]
      else
        [ "#{path}: a string must carry an enum, a const, format uuid or format date-time" ]
      end
    end
  end

  def check_ids_are_uuid(_type, schema, _registry)
    each_property(schema).flat_map do |path, sub|
      name = path.split(".").last
      if name.end_with?("_id")
        sub["format"] == "uuid" ? [] : [ "#{path}: an id is format uuid" ]
      elsif name.end_with?("_ids")
        sub["type"] == "array" && sub.dig("items", "format") == "uuid" ? [] : [ "#{path}: ids are an array of uuid" ]
      else
        []
      end
    end
  end

  # A credential appears by its id only: never its name, email, plan or folder.
  def check_credential_by_id_only(_type, schema, _registry)
    each_property(schema).filter_map do |path, _sub|
      name = path.split(".").last
      next unless name.include?("credential") || name.match?(/email|plan|folder|secret|password|keychain/)
      next if name.end_with?("credential_id")

      "#{path}: a credential is named by its id only"
    end
  end

  def check_enum_matches_list(type, schema, registry)
    ENUM_LISTS.flat_map do |(list_type, property), (vocabulary, relation)|
      next [] unless list_type == type

      sub = schema.dig("properties", property)
      next [ "#{property}: missing" ] unless sub

      values = Array(sub["enum"]).compact
      expected = vocabulary(registry, vocabulary)
      ok = relation == :equal ? values.sort == expected.sort : values.any? && (values - expected).empty?
      ok ? [] : [ "#{property}: enum #{values.inspect} does not #{relation} #{vocabulary} #{expected.inspect}" ]
    end
  end

  # Every enum or const of strings is drawn from one registry vocabulary.
  def check_enum_from_registry(_type, schema, registry)
    vocabularies = all_vocabularies(registry)
    each_property(schema).flat_map do |path, sub|
      values = (Array(sub["enum"]) + (sub.key?("const") ? [ sub["const"] ] : [])).grep(String)
      next [] if values.empty?
      next [] if vocabularies.any? { |list| (values - list).empty? }

      [ "#{path}: #{values.inspect} is not drawn from one registry list" ]
    end
  end

  def check_required_fields(type, schema, _registry)
    (REQUIRED_FIELDS.fetch(type, []) - Array(schema["required"])).map { |name| "#{name} is a required field" }
  end

  def check_wait_cause(type, schema, registry)
    return [] unless WAIT_CAUSE_TYPES.include?(type)

    sub = schema.dig("properties", "wait_cause")
    return [ "wait_cause: missing" ] unless sub && Array(schema["required"]).include?("wait_cause")

    values = Array(sub["enum"])
    expected = registry.dig("lists", "wait_causes")
    values.compact.sort == expected.sort && values.include?(nil) ? [] : [ "wait_cause: enum must be lists.wait_causes and null" ]
  end

  def vocabulary(registry, name)
    case name
    when /\Alists\.(.+)\z/ then registry.fetch("lists").fetch(Regexp.last_match(1))
    when "hold_reasons" then registry["hold_reasons"].map { |entry| entry["reason"] }
    when "release_reasons" then registry["release_reasons"].map { |entry| entry["reason"] }
    when "job_kinds" then registry["job_kinds"].map { |entry| entry["kind"] }
    when "policy_effects" then registry["policy_effects"].values.flatten.uniq
    else registry.fetch(name)
    end
  end

  def all_vocabularies(registry)
    named = %w[hold_reasons release_reasons job_kinds policy_effects check_results hooks needs_you_items step_kinds next_kinds commands]
    named.map { |name| vocabulary(registry, name) } +
      registry["lists"].values +
      [ registry["refusals"].map { |entry| entry["code"] },
        registry["event_types"].map { |entry| entry["type"] },
        registry["credential_providers"].map { |entry| entry["provider"] } ]
  end

  # Every property schema at any depth, as [dotted path, schema]. Array
  # items are walked under the array's path; local $refs are followed.
  def each_property(schema, root = schema, prefix = nil)
    schema.fetch("properties", {}).flat_map do |name, sub|
      path = [ prefix, name ].compact.join(".")
      sub = resolve(sub, root)
      [ [ path, sub ] ] + nested(sub, root, path)
    end
  end

  def nested(sub, root, path)
    found = []
    found += each_property(sub, root, path) if sub["properties"]
    items = sub["items"] && resolve(sub["items"], root)
    if items
      found << [ "#{path}[]", items ] if may_be_string?(items) && !closed?(items)
      found += each_property(items, root, path) if items["properties"]
    end
    %w[anyOf oneOf allOf].each do |keyword|
      Array(sub[keyword]).each { |branch| found += [ [ path, resolve(branch, root) ] ] }
    end
    found
  end

  def resolve(sub, root)
    ref = sub["$ref"]
    return sub unless ref&.start_with?("#/")

    ref.delete_prefix("#/").split("/").reduce(root) { |node, key| node.fetch(key) }
  end

  def may_be_string?(sub)
    return false if %w[anyOf oneOf allOf].any? { |keyword| sub.key?(keyword) } && !sub.key?("type")

    types = Array(sub["type"])
    types.empty? || types.include?("string") || (types - NON_STRING_TYPES).any?
  end

  def closed?(sub)
    sub.key?("enum") || sub.key?("const") || CLOSED_FORMATS.include?(sub["format"]) || sub["pattern"] == DIGEST_PATTERN
  end
end

class PayloadSchemasTest < Minitest::Test
  include ContractTestHelpers

  BAD_PAYLOADS = File.expand_path("fixtures/bad_payloads", __dir__)

  def registered
    registry["event_types"].flat_map do |entry|
      entry["schema_versions"].map { |version| [ entry["type"], version ] }
    end
  end

  def schema_for(type, version)
    Leverage::Contract.payload_schema(type, version)
  end

  def test_one_file_per_registered_type_and_version
    registered.each do |type, version|
      assert File.exist?(PayloadRules.file_for(type, version)), "missing payloads/#{type}.v#{version}.json"
    end
  end

  def test_no_orphan_payload_file
    expected = registered.map { |type, version| "#{type}.v#{version}.json" }
    present = Dir.glob("*", base: PayloadRules::PAYLOADS)
    assert_empty present - expected, "payload files with no registered (type, version)"
  end

  def test_each_title_names_its_type_and_version
    registered.each do |type, version|
      assert_equal "#{type} v#{version}", schema_for(type, version)["title"]
    end
  end

  PayloadRules.rules.each do |rule|
    define_method(:"test_every_payload_schema_passes_#{rule}") do
      registered.each do |type, version|
        errors = PayloadRules.errors(rule, type, schema_for(type, version), registry)
        assert_empty errors, "payloads/#{type}.v#{version}.json breaks #{rule}"
      end
    end
  end

  def test_every_example_validates_through_the_loader
    registered.each do |type, version|
      schema_for(type, version)["examples"].each do |example|
        assert_empty Leverage::Contract.validate_payload(type, version, example), type
      end
    end
  end

  # json_schemer asserts formats, so format uuid and date-time close a string.
  def test_formats_are_asserted
    schema = JSONSchemer.schema({ "type" => "object", "properties" => {
      "seat_id" => { "type" => "string", "format" => "uuid" },
      "reset_at" => { "type" => "string", "format" => "date-time" }
    } })
    refute schema.valid?({ "seat_id" => "builder-one" })
    refute schema.valid?({ "reset_at" => "tomorrow" })
    assert schema.valid?({ "seat_id" => "0b5e8c1a-2f43-4c8e-9d61-7a3f2e1b9c04", "reset_at" => "2026-11-18T12:00:00Z" })
  end

  def test_the_tables_name_registered_types_and_lists
    types = registry["event_types"].map { |entry| entry["type"] }
    tables = PayloadRules::REQUIRED_FIELDS.keys + PayloadRules::WAIT_CAUSE_TYPES +
      PayloadRules::ENUM_LISTS.keys.map(&:first) + PayloadRules::OPEN_STRINGS.keys.map(&:first)
    assert_empty tables.uniq - types
    PayloadRules::ENUM_LISTS.each_value do |vocabulary, _relation|
      refute_empty PayloadRules.vocabulary(registry, vocabulary), vocabulary
    end
  end

  def test_check_finished_and_task_released_carry_codes_only
    %w[check.finished task.released].each do |type|
      schema = schema_for(type, 1)
      refute_empty schema["properties"], type
      schema["properties"].each do |name, sub|
        next unless PayloadRules.may_be_string?(sub)

        assert PayloadRules.closed?(sub), "#{type}.#{name} is a code, not text"
      end
    end
  end

  # A rule check's input hash is a SHA-256 hex digest (Gating.input_hash),
  # in every payload that names a check.
  def test_check_payloads_carry_the_input_hash_as_a_digest
    %w[check.queued check.finished].each do |type|
      hash = schema_for(type, 1).fetch("properties").fetch("input_hash")
      assert_equal PayloadRules::DIGEST_PATTERN, hash["pattern"], type
      assert_equal "string", hash["type"], type
    end
  end

  # ARCHITECTURE: payloads hold no personal data; a model name is the one
  # open string, and it cannot hold an email address.
  def test_a_model_name_cannot_hold_an_email_address
    PayloadRules::OPEN_STRINGS.each_key do |type, property|
      pattern = Regexp.new(schema_for(type, 1).fetch("properties").fetch(property).fetch("pattern"))
      refute_match pattern, "someone@example.test", "#{type}.#{property}"
      assert_match pattern, "claude-model-1", "#{type}.#{property}"
    end
  end

  def test_negative_fixtures_cover_every_rule_named_in_the_plan
    breaks = bad_payloads.map { |fixture| fixture["breaks"] }
    %w[closed_strings enum_matches_list required_fields].each { |rule| assert_includes breaks, rule }
  end

  def test_each_negative_fixture_is_rejected_by_its_rule
    refute_empty bad_payloads
    bad_payloads.each do |fixture|
      rule = fixture.fetch("breaks")
      assert_includes PayloadRules.rules.map(&:to_s), rule, fixture["file"]
      errors = PayloadRules.errors(rule.to_sym, fixture.fetch("type"), fixture.fetch("schema"), registry)
      refute_empty errors, "#{fixture["file"]} passes #{rule}"
    end
  end

  # The fixture's type passes the same rule in the real contract, so the
  # doctored part is what fails.
  def test_each_negative_fixture_differs_from_a_passing_real_schema
    bad_payloads.each do |fixture|
      real = schema_for(fixture.fetch("type"), 1)
      assert_empty PayloadRules.errors(fixture["breaks"].to_sym, fixture["type"], real, registry), fixture["file"]
    end
  end

  private

  def bad_payloads
    Dir.glob(File.join(BAD_PAYLOADS, "*.json")).sort.map do |path|
      JSON.parse(File.read(path)).merge("file" => File.basename(path))
    end
  end
end
