require_relative "contract_helper"

class CredentialsContractTest < Minitest::Test
  include ContractTestHelpers

  def doc = Leverage::Contract.openapi
  def schemas = doc.fetch("components").fetch("schemas")
  def validator(name) = JSONSchemer.openapi(doc).ref("#/components/schemas/#{name}")

  def test_usage_read_due_is_an_eventless_workspace_command_on_every_sweep
    timer = Leverage::Contract.timers.fetch("timers").find { |entry| entry["timer"] == "usage_read_due" }
    refute_nil timer, "timers.json needs usage_read_due"
    assert_equal "workspace", timer["scope"]
    assert_equal "sweep_runs.ran_at", timer.dig("due_at", "source")
    assert_includes timer.dig("due_at", "plus"), "every sweep"
    assert_empty timer["events"]

    assert_includes registry.fetch("commands"), "usage_read_due"
    machine = Leverage::Contract.state_machine
    command = machine.fetch("commands").find { |entry| entry["command"] == "usage_read_due" }
    assert_equal [ false, false, false ], command.values_at("work_call", "blocked_by_hold", "allowed_while_pending")
    rows = machine.fetch("groups").find { |group| group["id"] == "timers" }.fetch("rows")
    rows = rows.select { |row| row["command"] == "usage_read_due" }
    assert_equal 1, rows.size
    assert_equal [ "app" ], rows.first["who"]
    assert_equal [ [], [], [] ], rows.first.values_at("events", "conditional_events", "side_events")
  end

  %w[reorder_credentials remove_credential].each do |command|
    define_method("test_#{command}_can_reevaluate_credential_holds") do
      rows = Leverage::Contract.state_machine.fetch("groups").find { |group| group["id"] == "credentials" }.fetch("rows")
      row = rows.find { |candidate| candidate["command"] == command }
      assert_equal %w[credential_limit credential_signed_out], row.fetch("holds_closed").sort

      events = row.fetch("side_events").to_h { |entry| [ entry.fetch("event"), entry ] }
      assert_equal %w[credential.switched hold.closed inbox.opened inbox.resolved], events.keys.sort
      assert_equal "credential_differs", events.dig("credential.switched", "when")
      note = events.dig("inbox.opened", "note")
      assert_includes note, "Limit with no reset time"
      assert_includes note, "Account signed out"
      refute_includes note, "SM-42"
    end
  end

  def test_the_add_credential_mask_example_and_schema_exclude_token_characters
    examples = schemas.fetch("AddCredentialRequest").fetch("examples")
    login = examples.find { |example| example["kind"] == "login" }
    token = examples.find { |example| example["kind"] == "api_token" }
    mask = "••••••••"
    assert_nil login.fetch("masked_label")
    assert_equal mask, token.fetch("masked_label")
    schema = validator("AddCredentialRequest")
    assert schema.valid?(login)
    assert schema.valid?(token)
    refute schema.valid?(token.merge("masked_label" => "abcd"))
  end

  def test_a_helper_reading_accepts_the_bounds_and_refuses_larger_values
    schema = validator("CredentialReading")
    example = schemas.fetch("CredentialReading").fetch("examples").first
    figure = example.fetch("figures").first.merge("label" => "x" * 80, "value" => "x" * 80)
    reset = example.fetch("resets").first
    reading = example.merge("tool_version" => "1" * 64, "figures" => [ figure ] * 32, "resets" => [ reset ] * 16)

    assert schema.valid?(reading)
    assert schema.valid?(reading.merge("tool_version" => nil, "resets" => nil))
    assert schema.valid?(reading.merge("figures" => [ figure.merge("value" => 0) ]))
    refute schema.valid?(reading.merge("tool_version" => "1" * 65))
    refute schema.valid?(reading.merge("figures" => [ figure ] * 33))
    refute schema.valid?(reading.merge("resets" => [ reset ] * 17))
    %w[label value].each do |field|
      refute schema.valid?(reading.merge("figures" => [ figure.merge(field => "x" * 81) ])), field
    end
  end

  def test_a_reorder_accepts_the_empty_set_and_still_requires_an_order
    schema = validator("ReorderCredentialsRequest")
    assert schema.valid?({ "order" => [] })
    refute schema.valid?({})
  end

  def test_the_credentials_list_example_pairs_each_reading_with_its_credential
    example = schemas.fetch("CredentialsList").fetch("examples").first
    row = example.fetch("credentials").first
    assert_equal row.fetch("credential").fetch("id"), row.fetch("reading").fetch("credential_id")
  end
end
