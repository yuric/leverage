module Leverage
  # The role files (PRD, The briefing: "four fixed texts shipped with the
  # app, one for each role but General"; GA-2, milestone 2 plan EN-6). Their
  # version is the app release, Leverage::VERSION, which the briefing hash
  # covers. They are in api/config/role_files/: the builder's and the
  # reviewer's since milestone 2, the planner's and the orchestrator's,
  # which a job's material carries (RD-30), since milestone 4.
  module RoleFiles
    module_function

    # The role file's text. Raises ArgumentError for a role with none.
    def text(role)
      raise ArgumentError, "no role file for #{role.inspect}" unless Roles.role_file?(role.to_s)

      (@texts ||= {})[role.to_s] ||= Rails.root.join("config/role_files/#{role}.md").read.freeze
    end

    # The version of every role file: the release.
    def version = Leverage::VERSION
  end
end
