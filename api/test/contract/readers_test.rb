require_relative "contract_helper"

# api/contract/readers.json: one credential reader per provider, which are
# provisional (PRD, What each account shows), and the shapes their readings
# and reports take (CredentialReading, LimitReport and SignOutReport in
# openapi.json). Assertions read registry.json only.
class ReadersTest < Minitest::Test
  include ContractTestHelpers

  def readers = Leverage::Contract.readers.fetch("readers")
  def by_provider = readers.to_h { |reader| [ reader["provider"], reader ] }
  def openapi = JSONSchemer.openapi(Leverage::Contract.openapi)

  def test_the_file_follows_its_meta_schema
    assert_empty meta_errors("readers", Leverage::Contract.readers)
  end

  def test_there_is_one_reader_per_registry_provider
    providers = registry.fetch("credential_providers")
    assert_empty duplicates(readers.map { |reader| reader["provider"] })
    assert_equal providers.map { |p| p["provider"] }, readers.map { |reader| reader["provider"] }
    providers.each { |p| assert_equal p["kind"], by_provider.fetch(p["provider"])["kind"], p["provider"] }
  end

  def test_every_login_reader_is_provisional_with_no_limit_or_sign_out_capture
    logins = readers.select { |reader| reader["kind"] == "login" }
    assert_equal %w[claude codex gemini grok], logins.map { |reader| reader["provider"] }
    logins.each do |reader|
      assert reader["provisional"], reader["provider"]
      assert_equal "none", reader.dig("capture", "limit"), reader["provider"]
      assert_equal "none", reader.dig("capture", "sign_out"), reader["provider"]
    end
  end

  def test_token_readers_are_provisional_until_a_reply_is_recorded_and_openai_is_not_verified
    tokens = readers.select { |reader| reader["kind"] == "api_token" }
    assert_equal 5, tokens.size
    tokens.each do |reader|
      assert_equal reader.dig("capture", "usage") == "none", reader["provisional"], reader["provider"]
    end
    assert_equal false, by_provider.fetch("openai_api")["verified"]
    assert_equal false, by_provider.fetch("gemini")["verified"], "every Gemini fact is unverified (PRD)"
  end

  def test_figures_and_resets_use_registry_vocabularies
    lists = registry.fetch("lists")
    readers.each do |reader|
      reader.fetch("figures").each do |figure|
        assert_includes lists["figure_kinds"], figure["kind"], reader["provider"]
        assert(figure["window"].nil? || lists["limit_windows"].include?(figure["window"]), reader["provider"])
        assert_equal "limit", figure["kind"] unless figure["window"].nil?
      end
      assert_empty reader.dig("resets", "kinds") - lists["reset_kinds"], reader["provider"]
    end
    assert_equal lists["reset_kinds"], by_provider.fetch("claude").dig("resets", "kinds")
    assert by_provider.fetch("codex").dig("resets", "available")
    %w[gemini grok].each { |provider| refute by_provider.fetch(provider).dig("resets", "available"), provider }
  end

  def test_each_example_reading_validates_against_credential_reading
    schema = openapi.ref("#/components/schemas/CredentialReading")
    readers.each do |reader|
      example = reader.fetch("example_reading")
      assert_empty schema.validate(example).map { |e| e.fetch("error") }, reader["provider"]
      assert_includes registry.dig("lists", "reading_states"), example["state"]
    end
  end

  def test_a_reading_shows_a_real_zero_and_a_missing_figure_as_null
    claude = by_provider.fetch("claude").fetch("example_reading")
    assert(claude["figures"].any? { |figure| figure["percent_used"] == 0 })
    unavailable = readers.map { |r| r["example_reading"] }.select { |reading| reading["state"] == "unavailable" }
    unavailable.each { |reading| assert_empty reading["figures"] }
  end

  def test_the_limit_and_sign_out_examples_validate_for_logins_and_are_absent_for_tokens
    limit = openapi.ref("#/components/schemas/LimitReport")
    sign_out = openapi.ref("#/components/schemas/SignOutReport")
    readers.each do |reader|
      if reader["kind"] == "login"
        assert_empty limit.validate(reader["example_limit_report"]).map { |e| e["error"] }, reader["provider"]
        assert_empty sign_out.validate(reader["example_sign_out_report"]).map { |e| e["error"] }, reader["provider"]
      else
        assert_nil reader["example_limit_report"], reader["provider"]
        assert_nil reader["example_sign_out_report"], reader["provider"]
      end
    end
  end

  def test_no_reader_names_a_secret_or_a_raw_reply
    forbidden = /secret|password|keychain|settings_folder|raw|header|email|(\A|_)token(_hash)?\z/i
    each_key(Leverage::Contract.readers) { |key| refute_match forbidden, key }
  end

  def test_the_two_reports_and_the_reading_carry_no_raw_reply
    openapi_doc = Leverage::Contract.openapi
    %w[CredentialReading LimitReport SignOutReport].each do |name|
      keys = openapi_doc.dig("components", "schemas", name, "properties").keys
      refute_includes keys, "raw_reply"
      refute_includes keys, "headers"
    end
  end

  private

  def each_key(node, &block)
    case node
    when Hash then node.each { |key, value| (yield key; each_key(value, &block)) }
    when Array then node.each { |value| each_key(value, &block) }
    end
  end
end
