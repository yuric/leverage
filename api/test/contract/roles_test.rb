require_relative "contract_helper"

# roles.json: the five seat roles, what each may change and read, the
# agent calls each may make, the roles each acts as and whether it gets a
# role file. The calls are checked against the registry's operations, the
# one list of every call. A General seat acts as each of the other four
# and gets no role file (contract decisions GA-1, GA-2).
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

  def test_each_role_acts_as_itself_and_the_general_role_as_every_other
    others = Leverage::Contract.list("seat_roles") - [ "general" ]
    roles.each do |entry|
      expected = entry["role"] == "general" ? others : [ entry["role"] ]
      assert_equal expected, entry["acts_as"], entry["role"]
    end
  end

  def test_the_general_role_makes_every_call_of_the_roles_it_acts_as
    general = roles.find { |entry| entry["role"] == "general" }
    refute_nil general
    acted = roles.select { |entry| general["acts_as"].include?(entry["role"]) }
    assert_equal acted.flat_map { |entry| entry["callers"] }.uniq.sort, general["callers"].sort
    assert_equal acted.flat_map { |entry| entry["operations"] }.uniq.sort, general["operations"].sort
  end

  def test_only_the_general_role_has_no_role_file
    assert_equal [ "general" ], roles.reject { |entry| entry["role_file"] }.map { |entry| entry["role"] }
    roles.each do |entry|
      file = File.expand_path("../../config/role_files/#{entry["role"]}.md", __dir__)
      assert_equal entry["role_file"], File.exist?(file), entry["role"]
    end
  end
end
