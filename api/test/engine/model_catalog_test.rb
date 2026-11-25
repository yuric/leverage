require "test_helper"

class ModelCatalogTest < ActiveSupport::TestCase
  Catalog = Leverage::ModelCatalog

  test "the catalog validates the exact provider model and the model's documented effort" do
    assert_includes Catalog.models("claude"), "claude-opus-5-5"
    assert_includes Catalog.efforts("claude", "claude-opus-5-5"), "high"
    assert_empty Catalog.efforts("claude", "")
    assert_empty Catalog.efforts("gemini", "gemini-4-neon")
    assert_empty Catalog.models("claude_api")

    assert_nil Catalog.problem(provider: "claude", model: "claude-opus-5-5", effort: "high", native: true)
    assert_match(/claude.*gpt-6.2-astra.*claude-opus-5-5/, Catalog.problem(provider: "claude", model: "gpt-6.2-astra", effort: "", native: false))
    assert_match(/claude-opus-5-5.*made-up.*high/, Catalog.problem(provider: "claude", model: "claude-opus-5-5", effort: "made-up", native: false))
  end

  test "driver support limits only Native effort; each Prompt model uses its own documented efforts" do
    catalog = Leverage::Contract.models.deep_dup
    model = catalog.fetch("providers").find { |entry| entry.fetch("provider") == "codex" }.fetch("models").first
    model["efforts"] = { "values" => [ "low" ] }

    original = Leverage::Contract.method(:models)
    Leverage::Contract.define_singleton_method(:models) { catalog }
    values = { provider: "codex", model: model.fetch("id"), effort: "low" }
    refute Catalog.native_effort?("codex")
    assert_nil Catalog.problem(**values, native: false)
    assert_match(/codex.*tool's default/, Catalog.problem(**values, native: true))
    assert_match(/model.*unknown/, Catalog.problem(**values, model: "", native: false))
  ensure
    Leverage::Contract.define_singleton_method(:models, original) if original
  end
end
