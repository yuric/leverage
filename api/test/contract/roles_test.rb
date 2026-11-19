require_relative "contract_helper"

# roles.json: the four seat roles, what each may change and read, and the
# agent calls each may make. The calls are checked against the registry's
# operations, the one list of every call.
class RolesTest < Minitest::Test
  include ContractTestHelpers

  def roles = Leverage::Contract.roles.fetch("roles")

  def test_validates_against_its_meta_schema
    assert_empty meta_errors("roles", Leverage::Contract.roles)
  end

  def test_roles_equal_the_seat_roles
    assert_equal Leverage::Contract.list("seat_roles"), roles.map { |entry| entry["role"] }
  end

  def test_calls_are_the_operations_of_the_role_callers
    roles.each do |entry|
      entry["callers"].each { |caller| assert_includes Leverage::Contract.list("operation_callers"), caller, entry["role"] }
      expected = registry["operations"].select { |op| entry["callers"].include?(op["caller"]) }.map { |op| op["operation_id"] }
      assert_equal expected.sort, entry["operations"].sort, entry["role"]
    end
  end

  def test_every_agent_call_belongs_to_a_role
    agent_calls = registry["operations"].select { |op| op["tag"] == "agent" }.map { |op| op["operation_id"] }
    assert_empty agent_calls - roles.flat_map { |entry| entry["operations"] }
    roles.each do |entry|
      entry["operations"].each do |operation_id|
        assert_equal "agent", registry["operations"].find { |op| op["operation_id"] == operation_id }["tag"], operation_id
      end
    end
  end

  def test_each_role_says_what_it_may_change_and_read
    roles.each do |entry|
      refute_empty entry["prd_may_change"].strip, entry["role"]
      refute_empty entry["prd_may_read"].strip, entry["role"]
    end
  end
end
