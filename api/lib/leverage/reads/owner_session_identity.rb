module Leverage
  module Reads
    module OwnerSessionIdentity
      module_function

      def call(caller)
        Snapshot.call(caller.workspace_id) do |as_of_seq|
          user = User.find_by!(id: caller.id, workspace_id: caller.workspace_id)
          { email_address: user.email_address, as_of_seq: as_of_seq }
        end
      end
    end
  end
end
