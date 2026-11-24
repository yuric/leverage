module Leverage
  # The contract names the roles each seat can act as and the material it gets.
  module Roles
    DEFINITIONS = Contract.roles.fetch("roles").index_by { |entry| entry.fetch("role") }.freeze

    module_function

    def acts_as?(role, acting_role)
      DEFINITIONS[role]&.fetch("acts_as")&.include?(acting_role) || false
    end

    def roles_acting_as(acting_role)
      DEFINITIONS.keys.select { |role| acts_as?(role, acting_role) }
    end

    def role_file?(role)
      DEFINITIONS[role]&.fetch("role_file") || false
    end

    def job_rules(role) = DEFINITIONS.fetch(role).fetch("job_rules")
  end
end
