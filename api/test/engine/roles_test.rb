require "test_helper"

class EngineRolesTest < ActiveSupport::TestCase
  test "acting roles, role files and job rules follow the contract" do
    assert Leverage.const_defined?(:Roles), "the engine needs a role reader"
    roles = Leverage::Roles
    definitions = Leverage::Contract.roles.fetch("roles")
    definitions.each do |definition|
      role = definition.fetch("role")
      assert_equal definition.fetch("role_file"), roles.role_file?(role)
      assert_equal definition.fetch("job_rules"), roles.job_rules(role)
      definitions.each do |other|
        acting = other.fetch("role")
        assert_equal definition.fetch("acts_as").include?(acting), roles.acts_as?(role, acting)
      end
      expected = definitions.select { |row| row.fetch("acts_as").include?(role) }.map { |row| row.fetch("role") }
      assert_equal expected, roles.roles_acting_as(role)
    end
  end
end
