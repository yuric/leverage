module Leverage
  module Reads
    # The Credentials tab (list_credentials; milestone 2 plan MA-20, IN-24):
    # every credential that has been added, in the owner's order. A row whose
    # Add credential is still running has not been verified yet, so it is not
    # an added credential and is left out (Credential.added). Each row says
    # since when it is limited, and until when if the provider said
    # (milestone 3 plan HE-3); both are the columns as they are, so a reset
    # time that has passed is still there and the reader compares it with
    # its own now. The newest usage reading comes from the same snapshot.
    module Credentials
      module_function

      # Raises ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id)
        Snapshot.call(workspace_id) do |as_of_seq|
          rows = Credential.added.where(workspace_id: workspace_id).order(:position, :id)
          { credentials: rows.map { |row| { credential: Shapes.credential(row), reading: reading_of(row) } }, as_of_seq: as_of_seq }
        end
      end

      def reading_of(credential)
        reading = CredentialReading.newest_for(credential).first
        return unless reading

        { credential_id: reading.credential_id, observed_at: Shapes.time(reading.observed_at), state: reading.state,
          tool_version: reading.tool_version, figures: reading.figures, resets: reading.resets }
      end
    end
  end
end
