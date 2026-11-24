require_relative "contract_helper"

# models.json: the model catalog (contract decisions UX-4 to UX-6b). One
# entry per login provider, each model with how it is known, and the efforts
# each model accepts only where the vendor's documentation names them. The
# server validates a seat's or a login's model and effort against it, and the
# Mac reads the same list from the generated ModelCatalog.swift.
class ModelsCatalogContractTest < Minitest::Test
  include ContractTestHelpers

  def catalog = Leverage::Contract.models
  def providers = catalog.fetch("providers")
  def login_providers = registry["credential_providers"].select { |entry| entry["kind"] == "login" }.map { |entry| entry["provider"] }
  def levels = catalog.fetch("evidence_levels")

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("models", catalog)
  end

  def test_the_evidence_levels_never_include_unverified_or_the_prd
    assert_equal [ "probe", "probe (full environment)", "help", "documented" ], levels
  end

  def test_every_login_provider_appears_once_and_no_other
    names = providers.map { |entry| entry["provider"] }
    assert_empty duplicates(names)
    assert_equal login_providers.sort, names.sort
  end

  def test_every_fact_names_an_allowed_level_a_source_and_a_date
    providers.each do |entry|
      facts = [ entry["native_effort"], entry["default_model"] ].compact + entry["models"]
      facts.each do |fact|
        assert_includes levels, fact["evidence"], entry["provider"]
        refute_empty fact["source"].to_s.strip, entry["provider"]
        assert_match(/\A\d{4}-\d{2}-\d{2}\z/, fact["checked_on"].to_s, entry["provider"])
      end
    end
  end

  # A probe or a help reading is recorded in the repository, so its source
  # is a path, never an address. The image holds only api/, so that the
  # path exists is checked by scripts/check_model_catalog.py.
  def test_a_probe_or_help_fact_cites_a_path_not_an_address
    providers.each do |entry|
      facts = [ entry["native_effort"], entry["default_model"] ].compact + entry["models"]
      facts.reject { |fact| fact["evidence"] == "documented" }.each do |fact|
        refute_match(%r{://}, fact["source"], "#{entry["provider"]}: #{fact["source"]} is not a repository path")
        refute fact["source"].start_with?("/"), "#{entry["provider"]}: #{fact["source"]} is absolute"
      end
    end
  end

  def test_model_ids_are_unique_within_a_provider
    providers.each do |entry|
      assert_empty duplicates(entry["models"].map { |model| model["id"] }), entry["provider"]
    end
  end

  def test_the_default_model_is_one_of_the_provider_models
    providers.each do |entry|
      next if entry["default_model"].nil?

      assert_includes entry["models"].map { |model| model["id"] }, entry["default_model"]["value"], entry["provider"]
    end
  end

  def test_efforts_come_from_documentation_only
    providers.each do |entry|
      entry["models"].each do |model|
        next if model["efforts"].nil?

        assert_equal "documented", model["efforts"]["evidence"], "#{entry["provider"]} #{model["id"]}"
        assert_empty duplicates(model["efforts"]["values"]), "#{entry["provider"]} #{model["id"]}"
      end
    end
  end

  # UX-15: an effort is offered only for a provider whose driver passes one.
  def test_a_provider_whose_driver_takes_no_effort_lists_none
    providers.reject { |entry| entry["native_effort"]["value"] }.each do |entry|
      entry["models"].each { |model| assert_nil model["efforts"], "#{entry["provider"]} #{model["id"]}" }
    end
  end

  def test_the_readme_lists_the_file_and_round_two
    readme = File.read(File.join(CONTRACT_ROOT, "README.md"))
    assert readme.include?("| `models.json` |"), "README lists models.json"
    section = readme.split(/^## /).find { |part| part.start_with?("What app round 2 changed") }
    refute_nil section, "README.md has no section for app round 2"
    %w[models.json create_task report_model seat_permissions add_task_limit deliver_turned_off].each do |name|
      assert section.include?(name), name
    end
  end

  def test_the_decisions_record_round_two
    decisions = File.read(File.join(CONTRACT_ROOT, "decisions.md"))
    assert decisions.include?("## App round 2 (UX)"), "decisions.md has the round 2 section"
    (1..16).each { |number| assert decisions.match?(/\*\*UX-#{number}[a-c]?\*\*/), "UX-#{number}" }
  end
end
