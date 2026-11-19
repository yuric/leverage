module Leverage
  module Reads
    # The Credentials tab (list_credentials; milestone 2 plan MA-20, IN-24):
    # every credential that has been added, in the owner's order. A row whose
    # Add credential is still running has not been verified yet, so it is not
    # an added credential and is left out. Usage readings arrive in milestone
    # 6, so every reading is null.
    module Credentials
      module_function

      # Raises ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id)
        Snapshot.call(workspace_id) do |as_of_seq|
          rows = Credential.where(workspace_id: workspace_id).where.not(last_verified_at: nil).order(:position, :id)
          { credentials: rows.map { |row| { credential: Shapes.credential(row), reading: nil } }, as_of_seq: as_of_seq }
        end
      end
    end
  end
end
