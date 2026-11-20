module Leverage
  module Transitions
    # The write behind a read (milestone 2 plan IN-10, DB-34, EN-20): what
    # the caller has been told is marked, under the workspace lock, with the
    # database clock. Neither is a command and neither writes an event.
    module MarkRead
      module_function

      # Sets commands.read_at, which clears `command` in GET /v1/next, the
      # first time the outcome is read. Returns whether it wrote.
      def command(row)
        return false unless Command.where(id: row.id, read_at: nil).exists?

        ActiveRecord::Base.transaction(requires_new: true) do
          _workspace, at = WorkspaceLock.take(row.workspace_id)
          Command.where(id: row.id, read_at: nil).update_all(read_at: at) == 1
        end
      end

      # Marks a queued helper request picked up (IF-15: the helper has it
      # now, and asks for its seat's token next). Returns the picked up
      # HelperRequest, or nil when it was not queued any more.
      def helper_request(request)
        ActiveRecord::Base.transaction(requires_new: true) do
          _workspace, at = WorkspaceLock.take(request.workspace_id)
          picked = ::HelperRequest.where(id: request.id, state: "queued")
            .update_all(state: "picked_up", picked_up_at: at, updated_at: at)
          ::HelperRequest.find(request.id) if picked == 1
        end
      end
    end
  end
end
