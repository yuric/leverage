module Leverage
  # The role files (PRD, The briefing: "four fixed texts shipped with the
  # app, one per role"; milestone 2 plan EN-6). Their version is the app
  # release, Leverage::VERSION, which the briefing hash covers. Milestone 2
  # ships the builder's and the reviewer's, in api/config/role_files/; the
  # planner's and the orchestrator's arrive with their roles in milestone 4.
  module RoleFiles
    ROLES = %w[builder reviewer].freeze

    module_function

    # The role file's text. Raises ArgumentError for a role with none.
    def text(role)
      raise ArgumentError, "no role file for #{role.inspect} in milestone 2" unless ROLES.include?(role.to_s)

      (@texts ||= {})[role.to_s] ||= Rails.root.join("config/role_files/#{role}.md").read.freeze
    end

    # The version of every role file: the release.
    def version = Leverage::VERSION
  end
end
