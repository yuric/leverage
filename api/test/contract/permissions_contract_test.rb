require_relative "contract_helper"

# A seat's permissions (contract decisions UX-10, UX-11a): Work on tasks,
# Deliver tasks and Create tasks, each on unless the owner turns it off. The
# seat read carries the whole set, Connect may send it (omitted is all on)
# and Change sends it whole. Turning Deliver off gives back the Working task
# with the app's release reason deliver_turned_off.
class PermissionsContractTest < Minitest::Test
  include ContractTestHelpers

  def doc = Leverage::Contract.openapi
  def schemas = doc.fetch("components").fetch("schemas")
  def sm = Leverage::Contract.state_machine
  def rows(command) = sm.fetch("groups").flat_map { |group| group["rows"] }.select { |row| row["command"] == command }
  def validator(component) = JSONSchemer.openapi(doc).ref("#/components/schemas/#{component}")

  def test_the_registry_lists_the_three_permissions
    assert_equal %w[work deliver create], Leverage::Contract.list("seat_permissions")
  end

  def test_the_permission_set_is_three_required_booleans
    shape = schemas.fetch("SeatPermissions")
    assert_equal false, shape["additionalProperties"]
    assert_equal Leverage::Contract.list("seat_permissions").sort, shape.fetch("required").sort
    assert_equal Leverage::Contract.list("seat_permissions").sort, shape.fetch("properties").keys.sort
    shape.fetch("properties").each_value { |property| assert_equal "boolean", property["type"] }
  end

  def test_a_seat_carries_its_permissions
    seat = schemas.fetch("Seat")
    assert_equal "#/components/schemas/SeatPermissions", seat.dig("properties", "permissions", "$ref")
    assert_includes seat.fetch("required"), "permissions"
    seat.fetch("examples").each { |example| assert validator("Seat").valid?(example), "Seat example" }
  end

  def test_connect_takes_an_optional_set_and_change_the_whole_set
    %w[ConnectSeatRequest ChangeSeatRequest].each do |name|
      shape = schemas.fetch(name)
      assert_equal "#/components/schemas/SeatPermissions", shape.dig("properties", "permissions", "$ref"), name
      refute_includes shape.fetch("required"), "permissions", name
    end
    partial = { "name" => "made-up", "role" => "general", "permissions" => { "work" => true } }
    refute validator("ConnectSeatRequest").valid?(partial), "a partial set is refused"
    whole = partial.merge("permissions" => { "work" => true, "deliver" => false, "create" => true })
    assert validator("ConnectSeatRequest").valid?(whole)
  end

  def test_deliver_off_gives_back_the_working_task
    reason = registry["release_reasons"].find { |entry| entry["reason"] == "deliver_turned_off" }
    refute_nil reason, "no release reason deliver_turned_off"
    assert_equal "app", reason["chosen_by"]
    payload = Leverage::Contract.payload_schema("task.released", 1)
    assert_includes payload.dig("properties", "reason", "enum"), "deliver_turned_off"
    assert_includes registry["guards"], "turns_deliver_off_holding_working_task"
    change = rows("change_seat").find { |row| row["who"].include?("owner") }
    assert_includes change["conditional_events"].map { |entry| entry.values_at("event", "when") },
      %w[task.released turns_deliver_off_holding_working_task]
  end

  # UX-1: new_prompt stays readable in old logs, and is written no more.
  def test_new_prompt_stays_in_the_registry_with_its_note
    reason = registry["release_reasons"].find { |entry| entry["reason"] == "new_prompt" }
    refute_nil reason
    assert_includes reason["note"].to_s, "only before app round 2"
    assert_includes Leverage::Contract.payload_schema("task.released", 1).dig("properties", "reason", "enum"), "new_prompt"
  end

  # The builder_availability guards read neither permission for an action
  # lease (UX-11a), and a task lease only for a seat that may deliver.
  def test_the_builder_availability_guards_say_what_reads_the_permissions
    family = sm.fetch("guard_families").find { |entry| entry["family"] == "builder_availability" }
    means = family.fetch("guards").map { |guard| guard["means"] }.join(" ")
    assert_includes means, "Deliver tasks"
    assert_includes means, "action lease"
  end

  def test_the_decisions_record_the_permissions
    decisions = File.read(File.join(CONTRACT_ROOT, "decisions.md"))
    %w[UX-10 UX-11a].each { |id| assert decisions.match?(/\*\*#{id}\*\*/), id }
  end
end
