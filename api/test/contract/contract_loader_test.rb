require_relative "contract_helper"
require "fileutils"
require "tmpdir"

# Leverage::Contract: loads every contract file once, frozen, and validates
# event payloads against their versioned schemas.
class ContractLoaderTest < Minitest::Test
  include ContractTestHelpers

  def teardown
    Leverage::Contract.root = nil
  end

  def test_the_default_root_is_the_contract_folder
    assert_equal File.realpath(CONTRACT_ROOT), File.realpath(Leverage::Contract.root.to_s)
  end

  def test_loads_every_contract_file_frozen
    files = Dir.glob("**/*.json", base: CONTRACT_ROOT).sort
    assert_includes files, "registry.json"
    files.each do |relative|
      data = Leverage::Contract.load(relative)
      assert deeply_frozen?(data), "#{relative} is not deeply frozen"
      assert_same data, Leverage::Contract.load(relative), "#{relative} is read once"
    end
  end

  def test_named_readers_return_the_parsed_files
    assert_equal Leverage::Contract.load("registry.json"), Leverage::Contract.registry
    %i[state_machine steps hooks shipped_rules jobs roles timers needs_you readers openapi].each do |reader|
      assert_respond_to Leverage::Contract, reader
    end
    assert_equal Leverage::Contract.load("meta/registry.schema.json"), Leverage::Contract.meta_schema("registry")
  end

  def test_every_meta_schema_is_a_valid_2020_12_schema
    metas = Dir.glob("meta/*.schema.json", base: CONTRACT_ROOT).sort
    refute_empty metas
    metas.each do |relative|
      schema = Leverage::Contract.load(relative)
      assert_equal "https://json-schema.org/draft/2020-12/schema", schema["$schema"], relative
      assert JSONSchemer.valid_schema?(schema), "#{relative} is not a valid JSON Schema"
    end
  end

  def test_list_returns_a_registry_list
    assert_equal registry["lists"]["task_states"], Leverage::Contract.list("task_states")
    assert_raises(KeyError) { Leverage::Contract.list("no_such_list") }
  end

  def test_event_type_returns_the_registry_entry
    entry = Leverage::Contract.event_type("task.created")
    assert_equal "task.created", entry["type"]
    assert_raises(KeyError) { Leverage::Contract.event_type("task.vanished") }
  end

  def test_every_registered_payload_example_validates
    registry["event_types"].each do |entry|
      entry["schema_versions"].each do |version|
        next unless File.exist?(File.join(CONTRACT_ROOT, "payloads", "#{entry["type"]}.v#{version}.json"))

        Leverage::Contract.payload_schema(entry["type"], version).fetch("examples").each do |example|
          assert_empty Leverage::Contract.validate_payload(entry["type"], version, example), entry["type"]
        end
      end
    end
  end

  def test_validate_payload_reports_an_unknown_property
    with_fixture_root do
      assert_empty Leverage::Contract.validate_payload("task.created", 1, { "state" => "backlog" })
      errors = Leverage::Contract.validate_payload("task.created", 1, { "state" => "backlog", "title" => "x" })
      refute_empty errors
      assert(errors.any? { |error| error.include?("title") }, errors.inspect)
    end
  end

  def test_validate_payload_reports_a_wrong_value_and_a_missing_field
    with_fixture_root do
      refute_empty Leverage::Contract.validate_payload("task.created", 1, { "state" => "working" })
      refute_empty Leverage::Contract.validate_payload("task.created", 1, {})
    end
  end

  def test_validate_payload_validates_the_stored_form_of_symbol_keys
    with_fixture_root do
      assert_empty Leverage::Contract.validate_payload("task.created", 1, { state: "ideas" })
    end
  end

  def test_validate_payload_raises_for_an_unregistered_type_or_version
    with_fixture_root do
      assert_raises(KeyError) { Leverage::Contract.validate_payload("task.vanished", 1, {}) }
      assert_raises(KeyError) { Leverage::Contract.validate_payload("task.created", 2, {}) }
    end
  end

  def test_setting_the_root_drops_what_was_read
    before = Leverage::Contract.registry
    with_fixture_root do
      refute_same before, Leverage::Contract.registry
      assert_equal [ "task.created" ], Leverage::Contract.registry["event_types"].map { |entry| entry["type"] }
    end
  end

  private

  def deeply_frozen?(value)
    return false unless value.frozen?

    case value
    when Hash then value.all? { |key, item| key.frozen? && deeply_frozen?(item) }
    when Array then value.all? { |item| deeply_frozen?(item) }
    else true
    end
  end

  # A contract folder with one registered type, so payload validation is
  # tested whatever payload files the real contract has.
  def with_fixture_root
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "payloads"))
      registry = { "event_types" => [ { "type" => "task.created", "schema_versions" => [ 1 ] } ] }
      File.write(File.join(dir, "registry.json"), JSON.generate(registry))
      schema = {
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "title" => "task.created v1",
        "type" => "object",
        "additionalProperties" => false,
        "required" => [ "state" ],
        "properties" => { "state" => { "enum" => %w[ideas backlog] } },
        "examples" => [ { "state" => "backlog" } ]
      }
      File.write(File.join(dir, "payloads", "task.created.v1.json"), JSON.generate(schema))
      Leverage::Contract.root = dir
      yield
    ensure
      Leverage::Contract.root = nil
    end
  end
end
