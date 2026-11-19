module Leverage
  module Reads
    # One helper request with each check's progress (get_helper_request;
    # milestone 2 plan IN-23, MA-20). What the app follows after Add
    # credential, Verify, Install, Start and Stop.
    #
    # With wait it long-polls (LongPoll, so it holds no connection between
    # looks) until the request changed after changed_after, an updated_at the
    # caller last saw, or wait runs out; it then answers the request as it
    # last looked, changed or not. Without changed_after it answers at once.
    module HelperRequest
      module_function

      # { request:, as_of_seq: }, or nil when the workspace has no such
      # request. Raises ActiveRecord::RecordNotFound for an unknown workspace.
      def call(workspace_id, id, wait: 0, changed_after: nil)
        answer = nil
        LongPoll.wait(wait) do
          answer = look(workspace_id, id)
          break if answer.nil?

          changed_after.nil? || answer.fetch(:updated_at) > changed_after
        end
        answer&.fetch(:status)
      end

      # One look, in a snapshot of its own. Uncached: the request's query cache
      # would answer every look after the first with the first look's row.
      def look(workspace_id, id)
        ActiveRecord::Base.uncached do
          Snapshot.call(workspace_id) do |as_of_seq|
            row = ::HelperRequest.find_by(workspace_id: workspace_id, id: id)
            row && { updated_at: row.updated_at, status: { request: Shapes.helper_request(row), as_of_seq: as_of_seq } }
          end
        end
      end
    end
  end
end
