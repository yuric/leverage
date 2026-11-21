module Leverage
  module Reads
    module WorkspaceSettings
      FIELDS = Contract.openapi.fetch("components").fetch("schemas").fetch("WorkspaceSettings").fetch("required")

      module_function

      def call(workspace_id) = from(Workspace.find(workspace_id))

      def from(workspace) = workspace.attributes.slice(*FIELDS)
    end
  end
end
