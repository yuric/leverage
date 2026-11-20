module Leverage
  module Reads
    # Runs a read's statements in one read-only, repeatable-read
    # transaction, so the rows it returns and the as_of_seq it reports are
    # one moment of the log (milestone 2 plan MA-20): under read committed a
    # read of several statements could report a position older or newer
    # than its rows. It cannot be opened inside another transaction, so a
    # test of a read is a CommittingTestCase.
    #
    #   Reads::Snapshot.call(workspace_id) do |as_of_seq|
    #     { as_of_seq: as_of_seq, tasks: Task.where(...).to_a }
    #   end
    module Snapshot
      module_function

      # Yields the workspace's last_seq read inside the snapshot, and returns
      # the block's value. Raises ActiveRecord::RecordNotFound for an unknown
      # workspace.
      def call(workspace_id)
        ActiveRecord::Base.transaction(isolation: :repeatable_read) do
          ActiveRecord::Base.lease_connection.execute("SET TRANSACTION READ ONLY")
          as_of_seq = Workspace.where(id: workspace_id).pick(:last_seq)
          raise ActiveRecord::RecordNotFound, "No workspace #{workspace_id}" if as_of_seq.nil?

          yield as_of_seq
        end
      end
    end
  end
end
